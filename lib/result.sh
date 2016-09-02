#!/bin/bash

. $LKP_SRC/lib/env.sh

export RESULT_MNT='/result'
export RESULT_PATHS='/lkp/paths'

set_tbox_group()
{
	local tbox=$1

	if [[ $tbox =~ ^(.*)-[0-9]+$ ]]; then
		tbox_group=$(echo ${BASH_REMATCH[1]} | sed -r 's#-[0-9]+-#-#')
	else
		tbox_group=$tbox
	fi
}

is_mrt()
{
	local dir=$1
	local -a jobs
	local -a matrix
	matrix=( $dir/matrix.json* )
	[ ${#matrix} -eq 0 ] && return 1
	jobs=( $dir/[0-9]*/job.yaml )
	[ ${#jobs} -ge 1 ]
}

# expand v4.1 etc. to commit SHA1
# eg: /gcc-4.9/v4.1/ => /gcc-4.9/b953c0d234bc72e8489d3bf51a276c5c4ec85345/
expand_tag_to_commit()
{
	local param=$1
	local project=$2
	local git_tag
	local commit

	[[ "$project" ]] || project="linux"

	[[ "$param" =~ (v[0-9].[0-9]+[_-rc0-9]*) ]] &&
	{
		git_tag=$BASH_REMATCH
		git_tag="${git_tag%/*}"

		commit=$(GIT_WORK_TREE="/c/repo/$project" GIT_DIR="$GIT_WORK_TREE/.git" \
				git rev-list -n1 "$git_tag" 2>/dev/null) &&
		[[ $commit ]] && param="${param/$git_tag/$commit}"
	}

	echo "$param"
}

cleanup_path_record_from_patterns()
{

	local pattern
	local flag_pattern=0
	local cmd
	local path_file
	local dot_temp_file
	local match_temp_file

	for pattern
	do
		pattern=$(expand_tag_to_commit $pattern)

		if [[ "$flag_pattern" = "0" ]]; then
			cmd="/${pattern//\//\\/}/"
			flag_pattern=1
		else
			cmd="$cmd && /${pattern//\//\\/}/"
		fi
	done

	[[ -d "/lkp/.paths/" ]] || mkdir "/lkp/.paths/" || return
	dot_temp_file=$(mktemp -p /lkp/.paths/ .tmpXXXXXX) || return
	match_temp_file=$(mktemp -p /lkp/.paths/ .tmpXXXXXX) || return
	chmod 664 $dot_temp_file || return

	for path_file in $(grep -l "$pattern" /lkp/paths/????-??-??-* /lkp/paths/.????-??-??-*)
	do
		awk -v file1="$match_temp_file" -v file2="$dot_temp_file"  "BEGIN {modified=0} $cmd {print >> file1; modified=1; next}; \
		{print > file2} END {exit 1-modified}" $path_file &&
		mv -f $dot_temp_file $path_file

	done

	cat $match_temp_file

	rm -f $dot_temp_file
	rm -f $match_temp_file

}

cleanup_path_record_from_result_root()
{

	local path=$1
	local cmd
	local path_file
	local dot_temp_file

	path=$(expand_tag_to_commit $path)
	cmd="/${path//\//\\/}/"

	[[ -d "/lkp/.paths/" ]] || mkdir "/lkp/.paths/" || return
	dot_temp_file=$(mktemp -p /lkp/.paths/ .tmpXXXXXX)
	chmod 664 $dot_temp_file || return

	for path_file in $(grep -l "$path" /lkp/paths/????-??-??-* /lkp/paths/.????-??-??-*)
	do
		lockfile-create -q --use-pid --retry 10 --lock-name "$path_file".lock

		awk "BEGIN {modified=0} $cmd {modified=1;next}; {print} END {exit 1-modified}" $path_file > $dot_temp_file &&
		mv -f $dot_temp_file $path_file

		lockfile-remove --lock-name "$path_file".lock
	done

	rm -f $dot_temp_file
}

is_local_server()
{
	[ "$LKP_SERVER" != "${LKP_SERVER#inn}" ] && return
	[ "$LKP_SERVER" != "${LKP_SERVER#192.168.}" ] && return
	return 1
}

upload_files()
{
	local file
	local ret=0

	if has_cmd rsync && is_local_server; then
		rsync -a --ignore-missing-args --min-size=1 "$@" rsync://$LKP_SERVER$JOB_RESULT_ROOT/
	elif has_cmd curl; then
		for file
		do
			[ -s "$file" ] || continue
			curl -T $file http://$LKP_SERVER$JOB_RESULT_ROOT/ || ret=$?
		done
		return $ret
	else
		# NFS is the last resort -- it seems unreliable, either some
		# content has not reached NFS server during post processing, or
		# some files occasionally contain some few '\0' bytes.
		for file
		do
			[ -s "$file" ] || continue
			chown lkp.lkp "$file"
			chmod ug+w    "$file"
			cp -p "$file" $RESULT_ROOT/ || ret=$?
		done
		[ "$ret" -ne 0 ] && ls -l "$@" $RESULT_ROOT 2>&1
		return $ret
	fi
}
