#!/bin/bash

set -o errexit -o errtrace -o nounset -o pipefail -o xtrace

GIT_SSH_COMMAND='ssh -i "$SSH_KEY_PATH" -l "$SSH_USERNAME"' \
    git fetch --depth 1 --force --no-tags origin "$GERRIT_BRANCH":"$GERRIT_BRANCH"

inputs=()
inputs+=("--volume $(pwd)/.git:/usr/src/app/.git")
inputs+=("--env GERGICH_DB_PATH=/home/docker/gergich")
inputs+=("--env GERGICH_PUBLISH=$GERGICH_PUBLISH")
inputs+=("--env GERGICH_KEY=$GERGICH_KEY")
inputs+=("--env GERRIT_HOST=$GERRIT_HOST")
inputs+=("--env GERRIT_PROJECT=$GERRIT_PROJECT")
inputs+=("--env GERRIT_BRANCH=$GERRIT_BRANCH")
inputs+=("--env GERRIT_EVENT_ACCOUNT_EMAIL=$GERRIT_EVENT_ACCOUNT_EMAIL")
inputs+=("--env GERRIT_PATCHSET_NUMBER=$GERRIT_PATCHSET_NUMBER")
inputs+=("--env GERRIT_PATCHSET_REVISION=$GERRIT_PATCHSET_REVISION")
inputs+=("--env GERRIT_CHANGE_ID=$GERRIT_CHANGE_ID")
inputs+=("--env GERRIT_CHANGE_NUMBER=$GERRIT_CHANGE_NUMBER")

# the GERRIT_REFSPEC is required for the commit message to actually
# send things to gergich
inputs+=("--env GERRIT_REFSPEC=$GERRIT_REFSPEC")

# Sometimes Docker doesn't clean up the volume completely and
# errors when trying to create the backing folder. Make it
# unique to avoid this.
GERGICH_VOLUME="gergich-results-$(date +%s)"
docker volume create $GERGICH_VOLUME

cat <<EOF | DOCKER_BUILDKIT=1 PROGRESS_NO_TRUNC=1 docker build \
  --build-arg PATCHSET_TAG="$PATCHSET_TAG" \
  --build-arg WEBPACK_BUILDER_TAG="$WEBPACK_BUILDER_IMAGE" \
  --tag "local/gergich" \
  -
# syntax=docker/dockerfile:experimental

ARG PATCHSET_TAG
ARG WEBPACK_BUILDER_TAG
FROM \$PATCHSET_TAG AS patchset
FROM \$WEBPACK_BUILDER_TAG
USER docker
RUN mkdir -p /home/docker/gergich
RUN --mount=type=bind,target=/tmp/src,source=/usr/src/app,from=patchset \
  cp -rf /tmp/src/. /usr/src/app
EOF

cat <<EOF | docker run --interactive ${inputs[@]} --volume $GERGICH_VOLUME:/home/docker/gergich local/gergich /bin/bash - &
set -ex
export COMPILE_ASSETS_NPM_INSTALL=0
export JS_BUILD_NO_FALLBACK=1
./build/new-jenkins/linters/run-and-collect-output.sh "gergich capture custom:./build/gergich/compile_assets:Gergich::CompileAssets 'rake canvas:compile_assets'"

gergich status
echo "WEBPACK_BUILD OK!"
EOF
WEBPACK_BUILD_PID=$!

cat <<EOF | docker run --interactive ${inputs[@]} --volume $GERGICH_VOLUME:/home/docker/gergich local/gergich /bin/bash - &
set -ex
# when parent is not in \$GERRIT_BRANCH (i.e. master)
if ! git merge-base --is-ancestor HEAD~1 \$GERRIT_BRANCH; then
  message="This commit is built upon commits not currently merged in \$GERRIT_BRANCH. Ensure that your dependent patchsets are merged first!\\n"
  gergich comment "{\"path\":\"/COMMIT_MSG\",\"position\":1,\"severity\":\"warn\",\"message\":\"\$message\"}"
fi

./build/new-jenkins/linters/run-and-collect-output.sh "gergich capture custom:./build/gergich/xsslint:Gergich::XSSLint 'node script/xsslint.js'"
./build/new-jenkins/linters/run-and-collect-output.sh "gergich capture i18nliner 'rake i18n:check'"
./build/new-jenkins/linters/run-and-collect-output.sh "bundle exec ruby script/brakeman"
./build/new-jenkins/linters/run-and-collect-output.sh "bundle exec ruby script/tatl_tael"
./build/new-jenkins/linters/run-and-collect-output.sh "bundle exec ruby script/stylelint"
./build/new-jenkins/linters/run-and-collect-output.sh "bundle exec ruby script/rlint"
./build/new-jenkins/linters/run-and-collect-output.sh "bundle exec ruby script/eslint"
./build/new-jenkins/linters/run-and-collect-output.sh "bundle exec ruby script/lint_commit_message"

gergich status
echo "LINTER OK!"
EOF
LINTER_PID=$!

cat <<EOF | docker run --interactive ${inputs[@]} --volume $GERGICH_VOLUME:/home/docker/gergich local/gergich /bin/bash - &
set -ex
readarray -t PLUGINS_LIST < config/plugins_list
rm -rf \$(printf 'gems/plugins/%s ' "\${PLUGINS_LIST[@]}")

export DISABLE_POSTINSTALL=1
./build/new-jenkins/linters/run-and-collect-output.sh "yarn install"

if ! git diff --exit-code yarn.lock; then
  message="yarn.lock changes need to be checked in. Make sure you run 'yarn install' without private canvas-lms plugins installed."
  gergich comment "{\"path\":\"yarn.lock\",\"position\":1,\"severity\":\"error\",\"message\":\"\$message\"}"
fi

gergich status
echo "YARN_LOCK OK!"
EOF
YARN_LOCK_PID=$!

wait $WEBPACK_BUILD_PID
wait $LINTER_PID
wait $YARN_LOCK_PID

cat <<EOF | docker run --interactive ${inputs[@]} --volume $GERGICH_VOLUME:/home/docker/gergich local/gergich /bin/bash -
set -ex
export GERGICH_REVIEW_LABEL="Lint-Review"
gergich status

if [[ "\$GERGICH_PUBLISH" == "1" ]]; then
  # we need to do this because it forces gergich to not use git (because no git repo is there).
  # and being that we rebased, the commit hash changes, so this will make it use the variables passed in
  export GERGICH_GIT_PATH=".."
  gergich publish
fi
EOF
