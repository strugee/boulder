#!/bin/bash
# Run all tests and coverage checks. Called from Travis automatically, also
# suitable to run manually. See list of prerequisite packages in .travis.yml
if type realpath >/dev/null 2>&1 ; then
  cd $(realpath $(dirname $0))
fi

# The list of segments to run. To run only some of these segments, pre-set the
# RUN variable with the ones you want (see .travis.yml for an example).
# Order doesn't matter. Note: godep-restore is specifically left out of the
# defaults, because we don't want to run it locally (would be too disruptive to
# GOPATH).
RUN=${RUN:-vet fmt migrations unit integration errcheck}

# The list of segments to hard fail on, as opposed to continuing to the end of
# the unit tests before failing.
HARDFAIL=${HARDFAIL:-fmt godep-restore}

FAILURE=0

DEFAULT_TESTPATHS=$(go list -f '{{ .ImportPath }}' ./... | grep -v /vendor/)
TESTPATHS=${TESTPATHS:-$DEFAULT_TESTPATHS}

GITHUB_SECRET_FILE="/tmp/github-secret.json"

start_context() {
  CONTEXT="$1"
  printf "[%16s] Starting\n" ${CONTEXT}
}

end_context() {
  printf "[%16s] Done\n" ${CONTEXT}
  if [ ${FAILURE} != 0 ] && [[ ${HARDFAIL} =~ ${CONTEXT} ]]; then
    echo "--------------------------------------------------"
    echo "---        A unit test or tool failed.         ---"
    echo "---   Stopping before running further tests.   ---"
    echo "--------------------------------------------------"
    exit ${FAILURE}
  fi
  CONTEXT=""
}

function run() {
  echo "$@"
  "$@" 2>&1
  local status=$?

  if [ "${status}" != 0 ]; then
    FAILURE=1
    echo "[!] FAILURE: $@"
  fi

  return ${status}
}

function run_and_expect_silence() {
  echo "$@"
  result_file=$(mktemp -t bouldertestXXXX)
  "$@" 2>&1 | tee ${result_file}

  # Fail if result_file is nonempty.
  if [ -s ${result_file} ]; then
    FAILURE=1
  fi
  rm ${result_file}
}

function die() {
  if [ ! -z "$1" ]; then
    echo $1 > /dev/stderr
  fi
  exit 1
}

function run_unit_tests() {
  if [ "${TRAVIS}" == "true" ]; then

    # The deps variable is the imports of the packages under test that
    # are not stdlib packages. We can then install them with the race
    # detector enabled to prevent our individual `go test` calls from
    # building them multiple times.
    all_shared_imports=$(go list -f '{{ join .Imports "\n" }}' ${TESTPATHS} | sort | uniq)
    deps=$(go list -f '{{ if not .Standard }}{{ .ImportPath }}{{ end }}' ${all_shared_imports})
    echo "go installing race detector enabled dependencies"
    go install -race $deps

    # Run each test by itself for Travis, so we can get coverage
    for path in ${TESTPATHS}; do
      dir=$(basename $path)
      go test -race -cover -coverprofile=${dir}.coverprofile ${path} || FAILURE=1
    done

    # Gather all the coverprofiles
    run gover

    # We don't use the run function here because sometimes goveralls fails to
    # contact the server and exits with non-zero status, but we don't want to
    # treat that as a failure.
    goveralls -v -coverprofile=gover.coverprofile -service=travis-ci
  else
    # When running locally, we skip the -race flag for speedier test runs. We
    # also pass -p 1 to require the tests to run serially instead of in
    # parallel. This is because our unittests depend on mutating a database and
    # then cleaning up after themselves. If they run in parallel, they can fail
    # spuriously because one test is modifying a table (especially
    # registrations) while another test is reading it.
    # https://github.com/letsencrypt/boulder/issues/1499
    run go test -p 1 $GOTESTFLAGS ${TESTPATHS}
  fi
}

#
# Run Go Vet, a correctness-focused static analysis tool
#
if [[ "$RUN" =~ "vet" ]] ; then
  start_context "vet"
  run_and_expect_silence go vet ${TESTPATHS}
  end_context #vet
fi

#
# Ensure all files are formatted per the `go fmt` tool
#
if [[ "$RUN" =~ "fmt" ]] ; then
  start_context "fmt"
  check_gofmt() {
    unformatted=$(find . -name "*.go" -not -path "./vendor/*" -print | xargs -n1 gofmt -l)
    if [ "x${unformatted}" == "x" ] ; then
      return 0
    else
      V="Unformatted files found.
      Please run 'go fmt' on each of these files and amend your commit to continue."

      for f in ${unformatted}; do
        V=$(printf "%s\n - %s" "${V}" "${f}")
      done

      # Print to stdout
      printf "%s\n\n" "${V}"
      [ "${TRAVIS}" == "true" ] || exit 1 # Stop here if running locally
      return 1
    fi
  }

  run_and_expect_silence check_gofmt
  end_context #fmt
fi

if [[ "$RUN" =~ "migrations" ]] ; then
  start_context "migrations"
  run_and_expect_silence ./test/test-no-outdated-migrations.sh
  end_context #"migrations"
fi

#
# Unit Tests.
#
if [[ "$RUN" =~ "unit" ]] ; then
  run_unit_tests
  # If the unittests failed, exit before trying to run the integration test.
  if [ ${FAILURE} != 0 ]; then
    echo "--------------------------------------------------"
    echo "---        A unit test or tool failed.         ---"
    echo "--- Stopping before running integration tests. ---"
    echo "--------------------------------------------------"
    exit ${FAILURE}
  fi
fi

#
# Integration tests
#
if [[ "$RUN" =~ "integration" ]] ; then
  # Set context to integration, and force a pending state
  start_context "integration"

  if [ -z "$CERTBOT_PATH" ]; then
    export CERTBOT_PATH=$(mktemp -d -t cbpXXXX)
    echo "------------------------------------------------"
    echo "--- Checking out letsencrypt client is slow. ---"
    echo "--- Recommend setting \$CERTBOT_PATH to  ---"
    echo "--- client repo with initialized virtualenv  ---"
    echo "------------------------------------------------"
    # Note: We check out the tag for the release that matches the
    # Debian-packaged Certbot version in the current letsencrypt/boulder-tools
    # Docker image.
    run git clone -b v0.8.1 --depth=1 https://www.github.com/certbot/certbot.git $CERTBOT_PATH || exit 1
  fi

  if ! type certbot >/dev/null 2>/dev/null; then
    source ${CERTBOT_PATH}/${VENV_NAME:-venv}/bin/activate
  fi

  run python test/integration-test.py --chisel
  end_context #integration
fi

# Run godep-restore (happens only in Travis) to check that the hashes in
# Godeps.json really exist in the remote repo and match what we have.
if [[ "$RUN" =~ "godep-restore" ]] ; then
  start_context "godep-restore"
  run_and_expect_silence godep restore
  # Run godep save and do a diff, to ensure that the version we got from
  # `godep restore` matched what was in the remote repo.
  cp Godeps/Godeps.json Godeps/Godeps.json.head
  run_and_expect_silence godep save ./...
  run_and_expect_silence diff <(sed /GodepVersion/d Godeps/Godeps.json.head) <(sed /GodepVersion/d Godeps/Godeps.json)
  run_and_expect_silence git diff --exit-code -- ./vendor/
  end_context #godep-restore
fi

#
# Run errcheck, to ensure that error returns are always used.
# Note: errcheck seemingly doesn't understand ./vendor/ yet, and so will fail
# if imports are not available in $GOPATH. So, in Travis, it always needs to
# run after `godep restore`. Locally it can run anytime, assuming you have the
# packages present in #GOPATH.
#
if [[ "$RUN" =~ "errcheck" ]] ; then
  start_context "errcheck"
  run_and_expect_silence errcheck \
    -ignore io:Write,os:Remove,net/http:Write,github.com/letsencrypt/boulder/metrics:.*,github.com/letsencrypt/boulder/vendor/github.com/cactus/go-statsd-client/statsd:.* \
    $(echo ${TESTPATHS} | tr ' ' '\n' | grep -v test)
  end_context #errcheck
fi

# Run generate to make sure all our generated code can be re-generated with
# current tools.
# Note: Some of the tools we use seemingly don't understand ./vendor yet, and
# so will fail if imports are not available in $GOPATH. So, in travis, this
# always needs to run after `godep restore`.
if [[ "$RUN" =~ "generate" ]] ; then
  start_context "generate"
  # Additionally, we need to run go install before go generate because the stringer command
  # (using in ./grpc/) checks imports, and depends on the presence of a built .a
  # file to determine an import really exists. See
  # https://golang.org/src/go/internal/gcimporter/gcimporter.go#L30
  # Without this, we get error messages like:
  #   stringer: checking package: grpc/bcodes.go:6:2: could not import
  #     github.com/letsencrypt/boulder/probs (can't find import:
  #     github.com/letsencrypt/boulder/probs)
  go install ./probs
  go install google.golang.org/grpc/codes
  run_and_expect_silence go generate ${TESTPATHS}
  # Because the `mock` package we use to generate mocks does not properly
  # support vendored dependencies[0] we are forced to sed out any references to
  # the vendor directory that sneak into generated resources.
  # [0] - https://github.com/golang/mock/issues/30
  goSrcFiles=$(find . -name "*.go" -not -path "./vendor/*" -print)
  run_and_expect_silence sed -i 's/github.com\/letsencrypt\/boulder\/vendor\///g' ${goSrcFiles}
  run_and_expect_silence git diff --exit-code $(ls | grep -v Godeps)
  end_context #"generate"
fi

if [[ "$RUN" =~ "rpm" ]]; then
  start_context "rpm"
  run make rpm
  end_context #"rpm"
fi

exit ${FAILURE}
