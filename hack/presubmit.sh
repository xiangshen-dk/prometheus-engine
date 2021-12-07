#!/usr/bin/env bash

# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail 

usage() {
      cat >&2 << EOF
usage: $(basename "$0") [all] [codegen] [crdgen] [diff] [docgen] [examples] [format] [test]
  $(basename "$0") executes presubmit tasks on the respository to prepare code
  before submitting changes. Running with no arguments runs every check
  (i.e. the 'all' subcommand).

EOF
}

SCRIPT_ROOT=$(dirname "${BASH_SOURCE[0]}")/..

codegen_diff() {
  TMPDIR=$(mktemp -d)
  git clone https://github.com/GoogleCloudPlatform/prometheus-engine ${TMPDIR}/prometheus-engine
  git diff -s --exit-code ${SCRIPT_ROOT}/pkg/operator/apis ${TMPDIR}/prometheus-engine/pkg/operator/apis
}

update_codegen() {
  echo ">>> regenerating CRD k8s go code"
  
  # Refresh vendored dependencies to ensure script is found.
  go mod vendor
  
  # Idempotently regenerate by deleting current resources.
  rm -rf $SCRIPT_ROOT/pkg/operator/generated
  
  CODEGEN_PKG=${CODEGEN_PKG:-$(cd "${SCRIPT_ROOT}"; ls -d -1 ./vendor/k8s.io/code-generator 2>/dev/null || echo ../code-generator)}
  
  # Invoke only for deepcopy first as it doesn't accept the pluralization flag
  # of the second invocation.
  bash "${CODEGEN_PKG}"/generate-groups.sh "deepcopy" \
    github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/generated github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/apis \
    monitoring:v1alpha1 \
    --go-header-file "${SCRIPT_ROOT}"/hack/boilerplate.go.txt \
    --output-base "${SCRIPT_ROOT}"
  
  bash "${CODEGEN_PKG}"/generate-groups.sh "client,informer,lister" \
    github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/generated github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/apis \
    monitoring:v1alpha1 \
    --go-header-file "${SCRIPT_ROOT}"/hack/boilerplate.go.txt \
    --plural-exceptions "Rules:Rules,ClusterRules:ClusterRules" \
    --output-base "${SCRIPT_ROOT}"
  
  cp -r $SCRIPT_ROOT/github.com/GoogleCloudPlatform/prometheus-engine/* $SCRIPT_ROOT
  rm -r $SCRIPT_ROOT/github.com
}

update_crdgen() {
  echo ">>> regenerating CRD yamls"

  which controller-gen || go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest

  CRD_DIR=${SCRIPT_ROOT}/cmd/operator/deploy/operator
  EXAMPLES_DIR=${SCRIPT_ROOT}/examples
  CRD_TMP=$(mktemp -d)
  
  # Split current crds.yaml into individual CRD files.
  csplit --quiet -f ${CRD_TMP}/crd- -b "%02d.yaml" ${CRD_DIR}/xx-crds.yaml "/---/+1" "{*}"
  
  # Re-generate each CRD patch separately (limitation of controller-gen).
  CRD_TMPS=$(find $CRD_TMP -iname '*.yaml' | sort)
  for i in $CRD_TMPS; do
    b=$(basename ${i})
    dir=${i%.yaml}
    mkdir -p ${dir}
    mv $i ${dir}/$b
    controller-gen schemapatch:manifests=${dir} output:dir=${dir} paths=./pkg/operator/apis/...
  done
  
  # Merge and overwrite crds.yaml. Remove last line so we don't produce
  # a final empty file that would make repeated runs of this script fail
  CRD_TMPS=$(find $CRD_TMP -iname '*.yaml' | sort)
  cat "${SCRIPT_ROOT}"/hack/boilerplate.txt > ${CRD_DIR}/crds-tmp.yaml
  echo -e "# NOTE: This file is autogenerated.\n" >> ${CRD_DIR}/crds-tmp.yaml
  sed -s '$a---' $CRD_TMPS | sed -e '$ d' -e '/^#/d' -e '/^$/d' >> ${CRD_DIR}/crds-tmp.yaml
  cp ${CRD_DIR}/crds-tmp.yaml ${CRD_DIR}/xx-crds.yaml
  mv ${CRD_DIR}/crds-tmp.yaml ${EXAMPLES_DIR}/setup.yaml
}

update_docgen() {
  echo ">>> generating API documentation"
  
  which po-docgen || (go get github.com/prometheus-operator/prometheus-operator \
    && go install -mod=mod github.com/prometheus-operator/prometheus-operator/cmd/po-docgen)
  mkdir -p doc
  po-docgen api ./pkg/operator/apis/monitoring/v1alpha1/types.go > doc/api.md
  sed -i 's/Prometheus Operator/GMP CRDs/g' doc/api.md
}

combine() {
  SOURCE_DIR=$1
  DEST_YAML=$2

  YAMLS=$(find ${SOURCE_DIR} -regextype sed -regex '^.*/[0-9][0-9]-\w.*.yaml$' | sort)
  cat "${SCRIPT_ROOT}"/hack/boilerplate.txt > $DEST_YAML
  echo -e "# NOTE: This file is autogenerated.\n" >> $DEST_YAML
  sed -s '$a---' $YAMLS | sed -e '$ d' -e '/^#/d' -e '/^$/d' >> $DEST_YAML
}

update_examples() {
  echo ">>> regenerating example yamls"

  combine ${SCRIPT_ROOT}/cmd/operator/deploy/operator ${SCRIPT_ROOT}/examples/operator.yaml
  combine ${SCRIPT_ROOT}/cmd/operator/deploy/rule-evaluator ${SCRIPT_ROOT}/examples/rule-evaluator.yaml
}

run_tests() {
  go test `go list ${SCRIPT_ROOT}/... | grep -v operator/e2e`
}

reformat() {
  go mod tidy && go mod vendor && go fmt ${SCRIPT_ROOT}/...
}

exit_msg() {
  echo $1
  exit 1
}

run_all() {
  # As this command can be slow, optimize by only running if there's difference
  # from the origin/main branch.
  codegen_diff || update_codegen
  reformat
  update_crdgen
  update_examples
  update_docgen
  run_tests
}

main() {
  if [[ -z "$@" ]]; then
    run_all
  else
    for opt in "$@"; do
      case "${opt}" in
        all)
          run_all
          ;;
        codegen)
          update_codegen
          ;;
        crdgen)
          update_crdgen
          ;;
        diff)
          git diff -s --exit-code doc go.mod go.sum '*.go' '*.yaml' || \
            exit_msg "diff found - ensure regenerated code is up-to-date and committed."
          ;;
        docgen)
          update_docgen
          ;;
        examples)
          update_examples
          ;;
        format)
          reformat
          ;;
        test)
          run_tests
          ;;
        *)
          echo -e "unsupported command: \"${opt}\".\n"
          usage
      esac
    done
  fi
}

main "$@"