# auditd_policy.bro
# Scott Campbell
#
# 
# Every login and related activities is associated with login session id (ses)
#   and the {pid} pair.  This collection of stuff identifies the key which
#   is actually the table used to hold multi action/record data.
#
# The ses id is monotomicly incrementing, so the odds of collision between many
#   systems is reasonably high.  Because of this the node identity is appended to 
#   ses and pid values since the internal systems should remove duplicate values.
#
@load auditd_core
@load util

module AUDITD_POLICY;

export {

	redef enum Notice::Type += {
		AUDITD_PermissionTransform,
		AUDITD_SocketOpen,
		};

	# List of identities which are consitered ok to be seen translating
	#  between one another.
	#
	global whitelist_to_id: set[string] &redef;
	global whitelist_from_id: set[string] &redef;

	### --- ###
	# This is the set of system calls that define the creation of a 
	#  network listening socket	
	global net_listen_syscalls: set[string];

	# Data struct to hold information about a generated socket
	type IPID: record {
		ip:      addr   &default=ADDR_CONV_ERROR;
		prt:     count  &default=PORT_CONV_ERROR;
		syscall: string &default=STRING_CONV_ERROR;
		#ts:	 time   &default=TIME_CONV_ERROR;
		error:   count  &default=0;
		}

	# this is a short term mapping designed to live for
	#   action duration
	ip_id_map: table[string] if IPID;

	# this tracks rolling execution history of user and is
	#   keyed on the longer lived whoami id
	execution_history: table[string] of set[string];

	} # end export
		
### ----- # ----- ###
#      Local Constants
### ----- # ----- ###
global NULL_ID: string = "-1";

global UID   = 1;
global GID   = 2;
global EUID  = 4;
global EGID  = 8;
global SUID  = 16;
global SGID  = 32;
global FSUID = 64;
global FSGID = 128;
global OGID  = 256;
global OUID  = 512;
global AUID  = 1024;


### ----- # ----- ###
#      Config
### ----- # ----- ###
redef net_listen_syscalls += { "bind", "accept", };

### ----- # ----- ###
#      Functions
### ----- # ----- ###


# This function compares two id values and in the event that
#  the post value are not whitelisted you get {0,1,2} 
#  depending on results.
function identity_atomic(old_id: string, new_id: string): count 
	{
	local ret_val = 0;

	if ( (new_id != old_id) && (old_id != NULL_ID) ) {
		# there has been a non-trivial change in identity
		if ( (new_id !in whitelist_to_id) && (old_id !in whitelist_from_id) )
			ret_val = 1;
		else
			ret_val = 2;
		}

	return ret_val;
	}

# Look for a unexpected transformation of the identity subvalues
#  returning a vector of changes.
#
function identity_test(whoami, auid: int, uid: int, gid: int, euid: int, egid: int, fsuid: int, fsgid: int, suid: int, sgid: int): count
	{
	# return value is a map of 
	local ret_val = 0;

	# Tests current set of provided identities against the current archived set
	#
	local t_Info = AUDITD_CORE::get_record(index,pid,ses,node);

	# In this case the record is either new or corrupt.
	if ( t_Info$uid == NULL_ID )
		return;

	# this is a mess, there *must* be a better way to do this ...
	if ( identity_atomic(t_Info$uid, uid) == 1 )
		ret_val = ret_val || UID;

	if ( identity_atomic(t_Info$gid, gid) == 1 )
		ret_val = ret_val || GID;
		
	if ( identity_atomic(t_Info$euid, euid) == 1 )
		ret_val = ret_val || EUID;

	if ( identity_atomic(t_Info$egid, egid) == 1 )
		ret_val = ret_val || EGID;

	if ( identity_atomic(t_Info$suid, suid) == 1 )
		ret_val = ret_val || SUID;

	if ( identity_atomic(t_Info$sgid, sgid) == 1 )
		ret_val = ret_val || SGID;

	if ( identity_atomic(t_Info$fsuid, fsuid) == 1 )
		ret_val = ret_val || FSUID;

	if ( identity_atomic(t_Info$fsgid, fsgid) == 1 )
		ret_val = ret_val || FSGID;

	if ( identity_atomic(t_Info$ouid, ouid) == 1 )
		ret_val = ret_val || OUID;

	if ( identity_atomic(t_Info$ogid, ogid) == 1 )
		ret_val = ret_val || OGID;

	if ( identity_atomic(t_Info$auid, auid) == 1 )
		ret_val = ret_val || AUID;

	return ret_val;
	}


function network_log_listener(index: string, whoami: string, s_host: string, s_serv: string, syscall: string) : count
function network_log_listener(i: AUDITD_CORE::Info) : count
	{
	# This captures data from the system calls bind() and
	#  accept() and checks to see if the system in question already
	#  has an open network listener
	#
	# Here use the ip_id_map to store data: use {ses}{node} as the
	#   table index.  Results for the listener will be handed over to the 
	#   systems object for further analysis.

	local ret_val = 0;
	local temp_index = fmt("%s%s", i$ses, i$node);
	local t_IPID: IPID;

	# normally the syscall happens before the saddr data arrives
	#   will not assume that everything will get here in the order that
	#   would be most convieniant to us ...
	if ( temp_index in ip_id_map ) 
		t_IPID = ip_id_map[temp_index];

	#
	if ( t_IPID$error != 0 )
		return 1;

	if ( i$s_host != "NO_HOST" ) {
		local t_ip = s_addr(s_host);

		if ( t_ip != ADDR_CONV_ERROR )
			t_IPID$ip = t_ip;
		else 	# error
			++t_IPID$error;

		}

	if ( i$s_serv != "NO_PORT" ) {
		local t_port = s_port(s_serv);

		if ( t_port != PORT_CONV_ERROR )
			t_IPID$prt = t_port;
		else 	# error
			++t_IPID$error;

		}

	if ( i$syscall != "NO_SYSCALL" ) {

		if ( syscall in net_listen_syscalls )
			t_IPID$syscall = syscall;
		else 	# error
			++t_IPID$error;

		}

	# now if there is sufficient information in the t_IPID structure we
	#  have enjoyed it long enough and should pass it off to the server object
	#  holding all the info on this system
	#
	if ( (t_IPID$syscall != STRING_CONV_ERROR) && (t_IPID$ip != ADDR_CONV_ERROR)) {
		# process the new listener.
		#
		event SERVER::holding();
		}

	ip_id_map[temp_index] = t_IPID;	

	return t_IPID$error;
	}


function network_register_conn(index: string, whoami: string, s_host: string, s_serv: string, syscall: string) : count
	{
	# This attempts to register outbound network connection data with a central correlator
	#  in order to link the {user:conn} with the "real" netwok connection as seen by the 
	#  external network facing bro.
	#
	# Connect() calls look like:
	# 


	}

### ----- # ----- ###
#      Events
### ----- # ----- ###

event auditd_policy_dispatcher(i: AUDITD_CORE::Info)
	{
	# This makes routing decisions for policy based on Info content.  It is
	#  a bit of a kluge, but will have to do for now.

	# Initial filtering based on action and key values
	#  ex: {PLACE_OBJ, PATH} .

	# Key is from audit.rules
	#
	local action = i$action;
	local key    = i$key;
	local syscall = i$syscall;	

        switch ( action ) {
        case "EXECVE":
                break;
        case "GENERIC":
                break;
        case "PLACE":
                break;
        case "SADDR":
                break;
        case "SYSCALL":
		switch( syscall ) {
			# from syscalls: bind, connect, accept, accept4, listen, socketpair, socket
			# key: SYS_NET
			case "connect":
				network_register_conn(i);
				break;
			case "bind":
			case "listen":
			case "socket":
			case "socketpair":
				#network_log_listener(i);
				break;
			case "accept":
			case "accept4":
				break;
			}
                break;
        case "USER":
                break;
        }

	

	} # event end

# do a test for "where" somwthing is executed like /dev/shm ...

