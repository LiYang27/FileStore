#!/bin/bash

##
## GlobalProtect installation finialisation script.
##
## Fixes issues where GlobalProtect can't verify the server certificate as it
## isn't looking in the right place for CA certificates on distributions where
## OpenSSL trusts nothing by default. Also adds in a tcsh profile.d script for
## users who use tcsh rather than bash as their default shell.
##
## Tested on:
##  * Linux Mint 17
##  * Linux Mint 19
##  * Fedora 22
##  * Fedora 28
##  * Ubuntu 18 
##  * Red Hat Enterprise Linux 7
##  * Arch (to some extent)
##
## Author: Clayton Peters <c.l.peters@soton.ac.uk>
## Date: 2018-09-28 11:00:00 +0100 (BST)
##

# Constants
INITSCRIPT=/etc/init.d/gpd
SH_PANMSINIT=/etc/profile.d/PanMSInit.sh
CSH_PANMSINIT=/etc/profile.d/PanMSInit.csh
GP_HOST=globalprotect.soton.ac.uk

# For colour-printing
TPUT=$(which tput)
if [ "x$?" != "x0" ]; then
	TPUT="/bin/true"
fi

function echo_error {
	$TPUT bold
	$TPUT setaf 1
	echo "ERROR: $*"
	$TPUT sgr0
}

function echo_warn {
	$TPUT bold
	$TPUT setaf 3
	echo "WARN: $*"
	$TPUT sgr0
}

PREFER_DPKG=0
PREFER_RPM=0

BINARY=$0
ARG=$1
while [ "x$ARG" != "x" ]; do
	case "${ARG}" in
		--prefer-dpkg)
			if [ "x$PREFER_RPM" == "x1" ]; then
				echo_error "Only one of --prefer-dpkg and --prefer-rpm may be specified"
				exit 1;
			fi
			PREFER_DPKG=1
			;;
		--prefer-rpm)
			if [ "x$PREFER_DPKG" == "x1" ]; then
				echo_error "Only one of --prefer-dpkg and --prefer-rpm may be specified"
				exit 1;
			fi
			PREFER_RPM=1
			;;
		--no-color|--no-colour)
			TPUT="/bin/true"
			;;
		-h|--help|-?)
			echo "Usage: $(basename $BINARY) [--prefer-dpkg|--prefer-rpm] [--no-color,--no-colour] [-h,-?,--help]"
			echo "  --prefer-dpkg             If both dpkg and rpm are found, dpkg will be used"
			echo "  --prefer-rpm              If both dpkg and rpm are found, rpm will ne used"
			echo "  --no-color,--no-colour    Print warnings and errors without formatting"
			echo "  --help,-h,-?              Print this help message"
			exit 0;
			;;
		*)
			echo_error "Unrecognised option: ${ARG}"
			exit 1;
			;;
	esac
	shift
	ARG=$1
done

# Make sure we're running as root
if [ "x`id -u`" != "x0" ]; then
	echo_error "This script must be run as root. Try: sudo $0"
	exit 1
fi

# Try to determine if we're an rpm-based system
RPMPATH=$(which rpm 2>/dev/null)
if [ "x$?" == "x0" ]; then
	RPMFOUND=1
	echo "INFO: Discovered rpm binary at $RPMPATH"
else
	RPMFOUND=0
	echo "INFO: Couldn't locate rpm binary"
fi

# Try to determine if we're a dpkg-based system
DPKGPATH=$(which dpkg 2>/dev/null)
if [ "x$?" == "x0" ]; then
	DPKGFOUND=1
	echo "INFO: Discovered dpkg binary at $DPKGPATH"
else
	DPKGFOUND=0
	echo "INFO: Couldn't locate dpkg binary"
fi

# If we didn't find either rpm or dpkg, then we need some manual intervention
if [ "x$RPMFOUND" == "x0" ] && [ "x$DPKGFOUND" == "x0" ]; then
	echo_error "Could not find package manager. Please contact ServiceLine for assistance"
	exit 2
fi

# If we found both rpm and dpkg (!), then we need some manual intervention
if [ "x$RPMFOUND" == "x1" ] && [ "x$DPKGFOUND" == "x1" ]; then
	if [ "x$PREFER_DPKG" == "x1" ]; then
		RPMFOUND=0
		DPKGFOUND=1
		echo_warn "Found more than one package manager. Being forced to dpkg by options."
	elif [ "x$PREFER_RPM" == "x1" ]; then
		RPMFOUND=1
		DPKGFOUND=0
		echo_warn "Found more than one package manager. Being forced to rpm by options."
	else
		echo_error "Found more than one package manager. Try adding --prefer-dpkg or\n--prefer-yum to the command line for this script, or else contact ServiceLine\nfor assistance"
		exit 3
	fi
fi

# Try to determine if the GlobalProtect package is installed
PACKAGEFOUND=0
PACKAGEWARN=0
echo "INFO: Searching for globalprotect package..."
if [ "x$RPMFOUND" == "x1" ]; then
	# Search for the RPM
	rpm -qa globalprotect 2>/dev/null | grep -F globalprotect >/dev/null 2>/dev/null

	if [ "x$?" == "x0" ]; then
		echo "INFO: Detected installed globalprotect package by rpm"
		PACKAGEFOUND=1
	else
		echo_warn "Couldn't find installed globalprotect package by rpm"
		PACKAGEWARN=1
	fi
fi
if [ "x$DPKGFOUND" == "x1" ]; then
	# Search for the package
	dpkg-query --show globalprotect >/dev/null 2>/dev/null

	if [ "x$?" == "x0" ]; then
		echo "INFO: Detected installed globalprotect package by dpkg-query"
		PACKAGEFOUND=1
	else
		echo_warn "Couldn't find installed globalprotect package by dpkg-query"
		PACKAGEWARN=1
	fi
fi

# See if the globalprotect directory and binary exists
if [ ! -d /opt/paloaltonetworks/globalprotect ]; then
	echo_error "Couldn't find globalprotect installation directory. Is GlobalProtect installed?"
	exit 4
else
	if [ ! -x /opt/paloaltonetworks/globalprotect/globalprotect ]; then
		echo_error "Couldn't find globalprotect binary. Is GlobalProtect installed?"
		exit 5
	else
		echo "INFO: Detected globalprotect binary"
		PACKAGEFOUND=1
	fi
fi

# If we found the package in some way, but it wasn't from the package manager then warn
if [ "x$PACKAGEFOUND" == "x1" ] && [ "x$PACKAGEWARN" == "x1" ]; then
	echo_warn "GlobalProtect installation was found, but not by package manager. Expect errors from this script!"
fi

# Try to determine if we're using systemd or SysV init
INITLINK=$(readlink $(which init))
INITSYSTEMD=$(echo "$INITLINK" 2>/dev/null | grep -F systemd >/dev/null 2>/dev/null; echo $?)
SYSTEMCTLPATH=`which systemctl 2>/dev/null`

# If systemctl wasn't found, then assume not SysV Init
if [ "x$?" != "x0" ]; then
	SYSTEMD=0
	INIT=1
	echo "INFO: Assuming SysV Init-based system"
else
	# See if the SystemState is running (which should 
	$SYSTEMCTLPATH --no-pager show 2>/dev/null | grep -F -e SystemState=running -e SystemState=degraded >/dev/null 2>/dev/null
	if [ "x$?" != "x0" ]; then
		SYSTEMD=0
		INIT=1
		echo "INFO: Assuming SysV Init-based system"
	else
		SYSTEMD=1
		INIT=0
		if [ "x$INITSYSTEMD" != "x0" ]; then
			echo_warn "systemd seems to be present, but init doesn't seem to symlink to it. Expect this not to work!"
		else
			echo "INFO: Detected systemd-based system"
		fi
	fi
fi

if [ "x$SYSTEMD" == "x1" ]; then
	systemctl --no-pager status gpd.service 2>&1 | grep -F 'could not be found' >/dev/null 2>/dev/null
	if [ "x$?" == "x0" ]; then
		echo_error "Couldn't find systemd unit file gpd.service"
		exit 6
	else
		UNITFILEPATH=$(systemctl --no-pager show gpd.service | fgrep FragmentPath= | sed 's/^FragmentPath=//')
		if [ "x$UNITFILEPATH" == "x" ]; then
			echo_error "Couldn't determine location of systemd unit file gpd.service"
			exit 7
		fi

		echo "INFO: systemd unit file gpd.service located at $UNITFILEPATH"
	fi
fi

if [ "x$SYSTEMD" == "x0" ]; then
	if [ ! -f $INITSCRIPT ]; then
		echo_error "Couldn't find initscript for gpd"
		exit 8
	else
		echo "INFO: Initscript for gpd located at $INITSCRIPT"
	fi
fi

if [ ! -f $SH_PANMSINIT ]; then
	echo_error "Couldn't find profile.d script for PanMSInit"
	exit 9
fi

SSL_CA_VARIABLE=""
SSL_CA_VALUE=""

# These are various locations at which we might expect to find CA certs. Determine one to use
if [ -f /etc/pki/tls/certs/ca-bundle.crt ]; then
	SSL_CA_VARIABLE="SSL_CERT_FILE"
	SSL_CA_VALUE="/etc/pki/tls/certs/ca-bundle.crt"
elif [ -d /usr/lib/ssl/certs ] && test $(ls -1 /usr/lib/ssl/certs/*.{pem,crt} | wc -l) -gt 10; then
	SSL_CA_VARIABLE="SSL_CERT_DIR"
	SSL_CA_VALUE="/usr/lib/ssl/certs"
elif [ -d /etc/ssl/certs ] && test $(ls -1 /etc/ssl/certs/*.{pem,crt} | wc -l) -gt 10; then
	SSL_CA_VARIABLE="SSL_CERT_DIR"
	SSL_CA_VALUE="/etc/ssl/certs"
fi

if [ "x$SSL_CA_VARIABLE" == "x" ] || [ "x$SSL_CA_VALUE" == "x" ]; then
	echo_error "Unable to detect Certificate Authority certificate locations. Please contact ServiceLine for assistance"
	exit 10
else
	echo "INFO: Detected configuration setting for $SSL_CA_VARIABLE to be $SSL_CA_VALUE"
fi

# Determine if we need to create a PanMSInit.csh (for tcsh users) and if so, create it
if [ -f $CSH_PANMSINIT ]; then
	echo "INFO: $CSH_PANMSINIT already exists. To overwrite, delete this file and re-run this script"
else
	cat > $CSH_PANMSINIT << EOF
#!/bin/tcsh

set PANGPA=/opt/paloaltonetworks/globalprotect/PanGPA
setenv $SSL_CA_VARIABLE $SSL_CA_VALUE

(pgrep -u \$USER PanGPA > /dev/null) >& /dev/null

if (\$? != 0) then
	if (-f \$PANGPA) then
		\$PANGPA start &
	endif
endif
EOF
	chown root:root $CSH_PANMSINIT
	chmod 0644 $CSH_PANMSINIT
	echo "INFO: Created $CSH_PANMSINIT"
fi

# Determine if we need to modify PanMSInit.sh and if so, do
if ! grep "^export $SSL_CA_VARIABLE=" $SH_PANMSINIT >/dev/null 2>/dev/null; then
	sed -i "/^PANGPA=/aexport $SSL_CA_VARIABLE=$SSL_CA_VALUE" $SH_PANMSINIT
	echo "INFO: Updated $SH_PANMSINIT"
else
	echo "INFO: No need to update $SH_PANMSINIT"
fi

# Determine if we need to modify the systemd unit file
if [ "x$SYSTEMD" == "x1" ]; then
	if ! grep "^Environment=\"$SSL_CA_VARIABLE=" $UNITFILEPATH >/dev/null 2>/dev/null; then
		sed -i "/\[Service\]/aEnvironment=\"$SSL_CA_VARIABLE=$SSL_CA_VALUE\"" $UNITFILEPATH
		echo "INFO: Updated $UNITFILEPATH"
		systemctl daemon-reload
	else
		echo "INFO: No need to update $UNITFILEPATH"
	fi
else
	echo "INFO: Skipping systemd unit file update"
fi

# Determine if we need to modify the initscript file
if [ "x$INIT" == "x1" ]; then
	if ! grep "^export $SSL_CA_VARIABLE=" $INITSCRIPT >/dev/null 2>/dev/null; then
		sed -i "/^DAEMON=/aexport $SSL_CA_VARIABLE=$SSL_CA_VALUE" $INITSCRIPT
		echo "INFO: Updated $INITSCRIPT"
	else
		echo "INFO: No need to update $INITSCRIPT"
	fi
else
	echo "INFO: Skipping SysV Initscript update"
fi

echo "INFO: Attempting to restart GlobalProtect services..."

# Kill user session agent
killall -9 PanGPA

# Restart service
if [ "x$SYSTEMD" == "x1" ]; then
	systemctl restart gpd
fi
if [ "x$INIT" == "x1" ]; then
	service gpd restart
fi

echo
echo "----------"
echo
echo "GlobalProtect configuration update completed!"
echo "You will need to restart your computer to complete installation. Then use:"
echo
echo "  globalprotect connect -p $GP_HOST -u <your-username>"
echo
echo "to connect to the VPN. For further assistance, please contact ServiceLine."
echo
