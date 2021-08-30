#!/bin/sh
set -e

cd /app

##
# Utility functions
error() { echo "error: $*" >&2; }
die() { error "$*"; exit 1; }
toupper() { echo "$*" | tr '[a-z]' '[A-Z]'; }
tolower() { echo "$*" | tr '[A-Z]' '[a-z]'; }
regexp() {
        : 'regexp(): ' "$@"
        awk "/${1}/{exit 0;}{exit 1;}" <<EOF
${2}
EOF
}
ref2env()
{
        case "${GITHUB_REF}" in
        (refs/heads/*)	set -- "${GITHUB_REF##refs/heads/}";;
	(refs/tags/*)	set -- 'tag';;
	(*)		set -- 'unknown';;
        esac

        case "${1}" in
        (${INPUT_PROD:=tag})      set -- 'prod';;
        (${INPUT_STAGE:=master})  set -- 'stage';;
        (${INPUT_DEV:=develop}|*) set -- 'dev';;
        esac

        echo "${1}"
}


if test "${INPUT_DEBUG}" = 'true'; then
	set -x
	: '## Args'
	: "$@"
fi

test -n "${INPUT_REGION:=${AWS_DEFAULT_REGION}}" || die 'region unset'
echo "AWS_DEFAULT_REGION=${INPUT_REGION}" >> "${GITHUB_ENV}"
export INPUT_REGION

if test -z "${INPUT_WORKSPACE:=${TF_WORKSPACE}}"; then
	INPUT_WORKSPACE="$(ref2env)"
fi
echo "TF_WORKSPACE=${INPUT_WORKSPACE}" >> "${GITHUB_ENV}"
export TF_WORKSPACE=

test -n "${INPUT_REMOTE_STATE_BUCKET:=${REMOTE_STATE_BUCKET}}" || die 'remote_state_bucket unset'
echo "REMOTE_STATE_BUCKET=${INPUT_REMOTE_STATE_BUCKET}" >> "${GITHUB_ENV}"
export INPUT_REMOTE_STATE_BUCKET

test -n "${INPUT_REMOTE_LOCK_TABLE:=${REMOTE_LOCK_TABLE}}" || die 'remote_lock_table unset'
echo "REMOTE_LOCK_TABLE=${INPUT_REMOTE_LOCK_TABLE}" >> "${GITHUB_ENV}"
export INPUT_REMOTE_LOCK_TABLE

export INPUT_GITHUB_REPOSITORY="${GITHUB_REPOSITORY}"
export INPUT_GITHUB_SHA="${GITHUB_SHA}"
export INPUT_GITHUB_REF="${GITHUB_REF}"

GITHUB_OWNER="${GITHUB_REPOSITORY%%/*}"
export GITHUB_OWNER
echo "GITHUB_OWNER=${GITHUB_OWNER}" >> "${GITHUB_ENV}"
export INPUT_GITHUB_OWNER="${GITHUB_OWNER}"

GITHUB_PROJECT="${GITHUB_REPOSITORY##*/}"
export GITHUB_PROJECT
echo "GITHUB_PROJECT=${GITHUB_PROJECT}" >> "${GITHUB_ENV}"
export INPUT_GITHUB_PROJECT="${GITHUB_PROJECT}"

GIT_SHORT_REV="$(printf '%.7s' "${GITHUB_SHA}")"
echo "GIT_SHORT_REV=${GIT_SHORT_REV}" >> "${GITHUB_ENV}"
echo "::set-output name=git_short_rev::${GIT_SHORT_REV}"

##
# Attempt to track multiple invocations of the same action
GITHUB_ACTION_NAME="$(toupper "${GITHUB_ACTION}"|tr '-' '_')"
eval "GITHUB_ACTION_COUNT=\"\$$(toupper "{${GITHUB_ACTION_NAME}_COUNT}")\""
test -n "${GITHUB_ACTION_COUNT}" || GITHUB_ACTION_COUNT='0'
GITHUB_ACTION_COUNT="$((${GITHUB_ACTION_COUNT} + 1))"
GITHUB_ACTION_INSTANCE="${GITHUB_ACTION_NAME}_${GITHUB_ACTION_COUNT}"
echo "${GITHUB_ACTION_NAME}_COUNT=${GITHUB_ACTION_COUNT}" >> "${GITHUB_ENV}"

: 'Generating terraform.tf'
cat<<EOF>terraform.tf
terraform {
	backend "s3" {
		encrypt = true
		region = "${INPUT_REGION}"
		bucket = "${INPUT_REMOTE_STATE_BUCKET}"
		key="${GITHUB_REPOSITORY}/${GITHUB_ACTION}_${GITHUB_ACTION_COUNT}"
		dynamodb_table = "${INPUT_REMOTE_LOCK_TABLE}"
       }
}
EOF

if test -n "${INPUT_AWS_ASSUME_ROLE:=${AWS_ASSUME_ROLE}}"; then
	: 'Generating _aws_provider.tf'
	echo "AWS_ASSUME_ROLE=${INPUT_AWS_ASSUME_ROLE}" >> "${GITHUB_ENV}"
	role_external_id=
	if test -n "${INPUT_AWS_EXTERNAL_ID:=${AWS_EXTERNAL_ID}}"; then
		echo "AWS_EXTERNAL_ID=${INPUT_AWS_EXTERNAL_ID}" >> "${GITHUB_ENV}"
		role_external_id="external_id = \"${INPUT_AWS_EXTERNAL_ID}\""
	fi
	sed -e 's/^	//'<<EOF>_aws_provider.tf
	provider "aws" {
		region  = "${AWS_DEFAULT_REGION}"
		assume_role {
			role_arn = "${INPUT_AWS_ASSUME_ROLE}"
			session_name = "${GITHUB_ACTION_NAME}_${GITHUB_ACTION_COUNT}"
			${role_external_id}
		}
	}
EOF
	: 'Generating AWS Credstash Config'
	test -d "${HOME}/.aws" || mkdir -p "${HOME}/.aws"
	sed -e 's/^	//'<<EOF >"${HOME}/.aws/config"
	[default]
	output = json
	region = ${INPUT_REGION}
	duration_seconds = 1200

	[profile credstash]
	role_arn = ${INPUT_AWS_ASSUME_ROLE}
	source_profile = default
	region = ${INPUT_REGION}
	external_id = ${INPUT_AWS_EXTERNAL_ID}
EOF
	# WARNING DO NOT ECHO SECRETS
	set +x
	touch "${HOME}/.aws/credentials"
	chmod og-rwx "${HOME}/.aws/credentials"
	sed -e 's/^	//'<<EOF >"${HOME}/.aws/credentials"
	[default]
	aws_access_key_id = ${AWS_ACCESS_KEY_ID}
	aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
	export INPUT_AWS_ASSUME_ROLE INPUT_AWS_EXTERNAL_ID
	test "${INPUT_DEBUG}" != 'true' || set -x
fi

: 'Generating _action_inputs.tf'
tfvar_number() {
cat<<EOF
variable "${1}" {
	type = number
}
EOF
}
tfvar_string() {
cat<<EOF
variable "${1}" {
	type = string
}
EOF
}
tfvar_map() {
cat<<EOF
variable "${1}" {
	type = map
}
EOF
}
tfvar_list() {
cat<<EOF
variable "${1}" {
	type = list
}
EOF
}
tfvar_bool() {
cat<<EOF
variable "${1}" {
	type = bool
}
EOF
}
tfvars()
{
	echo "INPUTS:" >&2
	##
	# Override any TF_VAR_*'s via INPUT_*'s
	# We have to itterate this in the current shell-context in order to
	# export the new values
	set +x
	for key in $(env|sed -E -n 's/^(INPUT_[^=]+).*/\1/p'); do
		case "${1}" in
		(*SECRET*|*PASSWORD*|*PASSWD*);;
		(*) test "${INPUT_DEBUG}" != 'true' || set -x;;
		esac

		: input: ${key}
		test "${key}" != 'workspace' || continue
		eval export "TF_VAR_$(tolower "${key#INPUT_}")='$(eval printf '%s' "\"\$${key}\""|tr -d '\n')'"
		test "${INPUT_DEBUG}" != 'true' || set -x
	done

	##
	# Itterate all TF_VAR settings into Terraform variable's on stdout
	env|grep ^TF_VAR|while read TF_VAR; do

		## avoid reporting secrets
		set +x
		case "${1}" in
		(*secret*|*password*|*passwd*);;
		(*) test "${INPUT_DEBUG}" != 'true' || set -x;;
		esac

                set -- "${TF_VAR%%=*}" "${TF_VAR#*=}"
                set -- "${1#TF_VAR_}" "${2}"
		if test "${1}" = 'workspace'; then
			continue
		elif regexp '^[0-9]+$' "${2}"; then
			tfvar_number "${1}" "${2}"
		elif regexp '^\{.*\}$' "${2}"; then
			tfvar_map "${1}"
		elif regexp '^\[.*\]$' "${2}"; then
			tfvar_list "${1}"
		elif test "${2}" = 'true'; then
			tfvar_bool "${1}" "${2}"
		elif test "${2}" = 'false'; then
			tfvar_bool "${1}" "${2}"
		else
			tfvar_string "${1}" "${2}"
		fi

		test "${INPUT_DEBUG}" != 'true' || set -x
	done
}

: 'Initializing Terraform'
cleanup() { rm -rf .terraform* terraform.tfstate.d; }
trap cleanup 0
export TF_IN_AUTOMATION='true'

if test "${INPUT_DEBUG}" = 'true'; then
	for file in *.tf; do
		printf "##\n# BEGIN ${file}\n"
		cat "${file}"
		printf "# END ${file}\n##\n\n"
	done
fi

terraform init
terraform workspace new prod  || :
terraform workspace new stage || :
terraform workspace new qa    || :
terraform workspace new dev   || :
terraform workspace select "${INPUT_WORKSPACE:=default}"

tfvars > _action_tfvars.tf
if test "${INPUT_DEBUG}" = 'true'; then
	: _action_tfvars.tf
	cat _action_tfvars.tf
fi
terraform init -reconfigure

# Allow overriding our entrypoint for debugging/development purposes
test "$#" -eq '0' || exec "$@"

# The above `exec` prevents us from reaching this code if the Docker CMD was specified

if test "${INPUT_PLAN:=true}" = 'true'; then
	: Terraform Plan
	terraform plan \
		-input=false \
		-compact-warnings
fi

if test "${INPUT_DESTROY:=false}" = 'true'; then
	: Terraform Destroy
	terraform destroy \
		-input=false \
		-compact-warnings \
		-auto-approve \
		${INPUT_ARGS}
fi

if test "${INPUT_DEPLOY:=true}" = 'true'; then
	: Terraform Apply
	terraform apply \
		-input=false \
		-compact-warnings \
		-auto-approve \
		${INPUT_ARGS}
fi

# Produce our Outputs
tf_keys()
{
	: _tf_keys: "${*}"
	echo "${*}" | jq -rc ".|keys|.[]"
}
tf_value()
{
	: _tf_value: "${*}"
	echo "${1}"| jq -rc ".[\"${2}\"]"
}

tf_out() {
	set -- "$(echo "${1}"|tr '-' '_')" "${2}"
	set -- "${1##_}" "${2}"
	set -- "${1%%_}" "${2}"
	echo "::set-output name=${1}::${2}"
	echo "TF_VAR_${1}=${2}" >> "${GITHUB_ENV}"
	eval "TF_VAR_${1}=\"${2}\""
}
tf_export()
{
	: _tf_export: "${@}"
	test "$(tf_value "${1}" 'sensitive')" != 'true' || return

	_tf_export_val="$(tf_value "${1}" 'value')"
	_tf_export_type="$(tf_value "${1}" 'type')"
	case "${_tf_export_type}" in

	(string) tf_out "${2}" "${_tf_export_val}" ;;

	(*map*|*object*)
		for _tf_key in $(tf_keys  "${_tf_export_val}"); do
			tf_out "${2}_${_tf_key}" "$(tf_value "${_tf_export_val}" "${_tf_key}")"
		done
		;;
	(*)	echo "WARNING: unknown type '${_tf_export_type}'" >&2;;
	esac
}

TERRAFORM_JSON="$(terraform output -json)"
for key in $(tf_keys  "${TERRAFORM_JSON}"); do
	tf_export "$(tf_value "${TERRAFORM_JSON}" "${key}")" "${key}"
done

if test -n "${INPUT_TF_ASSUME_ROLE}"; then
	echo "AWS_ASSUME_ROLE=arn:aws:iam::${TF_VAR_account_id}:role/${INPUT_TF_ASSUME_ROLE}" >> "${GITHUB_ENV}"
	if test -n "${TF_VAR_external_id}"; then
		echo "AWS_EXTERNAL_ID=${TF_VAR_external_id}" >> "${GITHUB_ENV}"
	fi
fi
