#!/bin/bash
#set -vx

passwd=$1
masterhost=
rootdir=$HOME/.starksync
logfile=$rootdir/.lastsync.log

no_colour="\e[0m"
white="\e[30;107m"
orange="\e[30;43m"

catch() {
	printf "=== script stopped (exit=$2) | failed while [ $1 ] @ $(date) ===\n"
	exit 1
}

logcmd() {
	echo "===" >> $logfile
	echo "=== executing [ ($1) ] @ $(date) ===" >> $logfile
	echo "===" >> $logfile
}

run_sudo() {
	dummy_sudo="gpg -d -q $HOME/.passwd.gpg | sudo -S sleep 0 >> $logfile 2>&1"
	echo "=== DUMMY SUDO COMMAND" >> $logfile
	echo "=== executing [ ($dummy_sudo) ] @ $(date) ===" >> $logfile
	echo "===" >> $logfile
	eval $dummy_sudo || catch "running dummy sudo" "$?"
	# don't run in subshell
	sudo_cmd="gpg -d -q $HOME/.passwd.gpg | sudo -S $@ >> $logfile 2>&1"
	logcmd "$sudo_cmd"
	eval $sudo_cmd || catch "running sudo for: $@" "$?"
}

gpg_setup_and_encrypt() {
	(gpg --batch --passphrase '' --quick-gen-key USER_ID default default >> $logfile 2>&1) || catch "creating gpg key" "$?"
	(gpg --export > $HOME/.gnupg/public.key) || catch "exporting public key" "$?"
	(echo $passwd > .passwd && gpg -e -f $HOME/.gnupg/public.key .passwd >> $logfile 2>&1 && rm .passwd || rm .passwd) || catch "encrypting passwd file" "$?"
}

install_deps() {
	(run_sudo yum -y install sshpass >> $logfile 2>&1) || catch "installing sshpass" "$?"
}

try_initial_setup() {
	if [ ! -f $HOME/.passwd.gpg ]
	then
		gpg_setup_and_encrypt
		install_deps
	fi
	if [ ! -d $rootdir ]
	then
		mkdir -p $rootdir
	fi
	touch $rootdir/.initial_setup_done
}

do_presync() {
	printf "starting file sync...\n"
	INIT_TIME=${SECONDS}
	echo "checking .rsync_commands hash" >> $logfile
	rsync_line="rsync -azv $USER@$masterhost:$rootdir/.rsync_commands $rootdir/.rsync_commands_master"
	rsync_cmd="(gpg -d -q $HOME/.passwd.gpg | sshpass $rsync_line >> $logfile 2>&1)"
	logcmd "$rsync_cmd"
	eval $rsync_cmd || { printf "\n"; catch "trying to sync .rsync_commands_master file" "$?"; }
	while [ ! -f $rootdir/.rsync_commands_master ]
  do
	  sleep 1
	done
	ls -la $rootdir >> $logfile
	my_md5=$(md5sum $rootdir/.rsync_commands | cut -d' ' -f 1 -s)
	real_md5=$(md5sum $rootdir/.rsync_commands_master | cut -d' ' -f 1 -s)
	echo "local md5sum for $rootdir/.rsync_commands: $my_md5" >> $logfile
	echo "remote md5sum for $rootdir/.rsync_commands_master: $real_md5" >> $logfile
	if [[ "$real_md5" != "$my_md5" ]]
	then
		cat << EOL
###
### $(echo -e "${orange}[ WARNING ]${no_colour}")
###
### your local ($rootdir/.rsync_commands) file is out of sync with the master
### it can be updated by running: $(echo -e "${white}starksync -r${no_colour}")
### the diff can be found in ($rootdir/.lastsync.log)
###
EOL
		echo "adding .rsync_commands diff to log" >> $logfile
		echo "=== DIFF FOR .rsync_commands FILES" >> $logfile
		diff -u $rootdir/.rsync_commands $rootdir/.rsync_commands_master >> $logfile
		echo "===" >> $logfile
	fi
	rm $rootdir/.rsync_commands_master > /dev/null 2>&1
	echo "initial setup finished or skipped, moving to rsync commands" >> $logfile
}

do_sync() {
	if [ -f $rootdir/.rsync_commands ]
	then
		shopt -s checkwinsize; (:;:)
		((width=COLUMNS-4))
		current=0
		total=$(cat $rootdir/.rsync_commands | wc -l)
		if [[ "$total" -ge 1 ]]
		then
			while read line; do
				# TODO: add regex matcher for \# so that rsync_commands can be commented out
				((current++))
				((progress=(($current*width))/total))
				((percentage=((progress*100))/width))
				rsync_cmd="(gpg -d -q $HOME/.passwd.gpg | sshpass $line >> $logfile 2>&1)"
				logcmd "$rsync_cmd"
				eval $rsync_cmd || catch "running rsync command ($current)" "$?"
				printf '\r|\e[4%dm%*s\e[m' "${color:-7}" "${progress}"
				printf '\e[%dG|%d%%' "${width}" "${percentage}"
			done < $rootdir/.rsync_commands
		fi
	else
		catch "trying to run rsync: $rootdir/.rsync_commands does not exist" "$?"
	fi
}

do_argsync() {
	if [[ "$sync_rsync" == "true" ]]
	then
		printf "[ syncing newest rsync_commands from ($masterhost) ] "
		rsync_line="rsync -azv $USER@$masterhost:$rootdir/.rsync_commands $rootdir"
		rsync_cmd="(gpg -d -q $HOME/.passwd.gpg | sshpass $rsync_line >> $logfile 2>&1)"
		eval $rsync_cmd || { printf "\n"; catch "trying to sync .rsync_commands file" "$?"; }
		printf "[ done ]\n"
	fi
	if [[ "$sync_remmina" == "true" ]]
	then
		printf "[ syncing newest remmina config to ($masterhost) ] "
		rsync_line="rsync -azv $HOME/.local/share/remmina $USER@$masterhost:$HOME/.local/share"
		rsync_cmd="(gpg -d -q $HOME/.passwd.gpg | sshpass $rsync_line >> $logfile 2>&1)"
		eval $rsync_cmd || { printf "\n"; catch "trying to sync .rsync_commands file" "$?"; }
		printf "[ done ]\n"
	fi
}

do_gnomesync() {
	if [[ "$sync_gnome" == "true" ]]
	then
		################## load gnome config
		run_sudo "dconf load / < $rootdir/.gnome_config"
	fi
}

do_postsync() {
	################## send successful sync ack
	printf "[ sending ack ] "
	echo $(date --date="next day" +"%m/%d/%Y") > $rootdir/.next_sync
	syncfile=$rootdir/.successful_syncs
	if [ ! -f $syncfile ]
	then
		touch $syncfile
	fi
	if grep -q "$HOSTNAME" "$syncfile"
	then
		new_sync_time=$(date +"%m\\/%d\\/%Y @ %H:%M:%S")
		perl -i -pe "s/$HOSTNAME - \K.*(?=\n)/$new_sync_time/" $syncfile
	else
		echo "$HOSTNAME - $(date +"%m/%d/%Y @ %H:%M:%S")" >> $syncfile
	fi
	cat $syncfile | sort -t' ' -k3.7,3.10r -k3.1,3.2r -k3.4,3.5r -k5.1,5.2r -k5.4,5.5r -k5.7,5.8r > ${syncfile}_tmp
	mv ${syncfile}_tmp $syncfile
	rsync_cmd="rsync -azv $syncfile $USER@$masterhost:$rootdir"
	ack_cmd="(gpg -d -q $HOME/.passwd.gpg | sshpass $rsync_cmd >> $logfile 2>&1)"
	logcmd "$ack_cmd"
	eval $ack_cmd || catch "sending successful sync ack" "$?"
	################## announce sync finished
	printf "[ sync finished in $((${SECONDS}-${INIT_TIME})) seconds ]\n"
}

_entrypoint() {
  rm $logfile > /dev/null 2>&1
	echo "sync started: $(date)" > $logfile
	if [ ! -f $rootdir/.initial_setup_done ]
	then
		try_initial_setup
	fi
	do_presync
	if [[ "$sync_rsync" == "true" || "$sync_remmina" == "true" ]]
	then
		do_argsync
	else
		do_sync
		do_gnomesync
	fi
	do_postsync
}

md2man() {
    pandoc --standalone --to man | man --local-file -
}

help_md() {
  cat <<MARKDOWN
% STARKSYNC(1)

# NAME
starksync - Sync config and files from your master host

# SYNOPSIS
| *starksync*
| *starksync* -r
| *starksync* -v
| *starksync* -g

# COMMANDS
starksync
: Run a normal file sync
  This will run all rsync commands in *.rsync_commands*

    [from] *master (remote)* -> [to] *clone (localhost)*

starksync -r
: Sync the latest *.rsync_commands* file from your master host
  Useful if you have made changes to *.rsync_commands* on your master host

    [from] *master (remote)* -> [to] *clone (localhost)*

starksync -v
: Sync new remmina vnc config back up to your master host
  Useful if you have configured a new vnc connection in remmina while using a clone host

    [from] *clone (localhost)* -> [to] *master (remote)*

starksync -g
: Run a normal file sync and load gnome config, this needs to be exported first
  - dconf dump /org/gnome/ > .gnome_config

  [from] *master (remote)* -> [to] *clone (localhost)*

MARKDOWN
}

while getopts 'rvgh' flag; do
	case "${flag}" in
		r) sync_rsync=true ;;
		v) sync_remmina=true ;;
		g) sync_gnome=true ;;
    h)
      help_md | md2man
      exit 0
      ;;
		*)
		  help_md | md2man
		  exit 1
		  ;;
	esac
done

_entrypoint
