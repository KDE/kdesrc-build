#!/bin/bash

VERSION="$1"

# User to run this script on behalf of
MY_USER="mpyne"

# Sed substitutions
REMOVE_MARKER='/REMOVE_FOR_INDEX/d'
VERSION_SUBST="s/\\\$VERSION/$VERSION/g"

# Other fun variables
WEB_PAGE_DIR="/var/www/localhost/htdocs/kdecvs-build"
FILE_LIST="HISTORY TODO AUTHORS COPYING doc.html \
           kdecvs-build kdecvs-buildrc-sample option-list"
FILE_NAME="kdecvs-build-$VERSION.tar.gz"

if [ $EUID -ne 0 ]; then
	echo "You must run this script as root!"
	exit 1
fi

if [ $# -ne 1 ]; then
	if [ $# -eq 2 -a $1 -eq --undo ]; then
		$VERSION="$2"

		# Delete the file
		rm -f "kdecvs-build-$VERSION.tar.gz"

		# Untag the repository
		CVS_VERSION=$(echo VERSION.$VERSION | sed 's/\./_/g' | tr a-z A-Z);
		su $MY_USER -c "cvs tag -d $CVS_VERSION > /dev/null"
		echo "CVS repository tags for $VERSION deleted."

		exit 0
	fi

	echo "You must pass the program version on the command line!"
	exit 1
fi

# Check that I didn't forget to alter the version in the script.
if [ "x`./kdecvs-build -v | grep '\b'$VERSION'\b'`" == "x" ]; then
	echo "kdecvs-build reports the wrong version, you must fix that first!"
	exit 1
fi

# Check that I actually committed the changes to CVS.
if [ "x`cvs diff $FILE_LIST 2>&1 | grep -v 'I know nothing'`" != 'x' ]; then
	echo "You must commit your changes to CVS before running this script!"
	exit 1
fi

if [ -e $FILE_NAME ]; then
	echo "$FILE_NAME already exists!!"
	echo "This script won't overwrite it, remove it yourself!"
	exit 2
fi

cp doc.html.in doc.html # Use this for now to approximate size

# Try to determine the size
TEMPNAME=`tempfile`
tar czf $TEMPNAME $FILE_LIST || { echo "Failed to create $TEMPNAME!"; exit 2; }
SIZE=$(du -h $TEMPNAME | cut -f 1);
SIZE_SUBST="s/\\\$SIZE/$SIZE/g" # Define sed substitution
rm -f $TEMPNAME
echo "Archive size around $SIZE"

# Now remove the old doc.html
rm doc.html

# First tag the CVS repository with the version name.
CVS_VERSION=$(echo VERSION.$VERSION | sed 's/\./_/g' | tr a-z A-Z);
su $MY_USER -c "cvs tag $CVS_VERSION > /dev/null"
echo "CVS repository tagged"

# Generate doc.html now
su $MY_USER -c "sed '$VERSION_SUBST;$SIZE_SUBST' doc.html.in > doc.html"
echo "doc.html generated"

# Create tar file with the given packages.
su $MY_USER -c "mkdir kdecvs-build-$VERSION"
su $MY_USER -c "cp $FILE_LIST kdecvs-build-$VERSION"
su $MY_USER -c "tar czf $FILE_NAME kdecvs-build-$VERSION"
rm -r "kdecvs-build-$VERSION/"
echo "Archive $FILE_NAME created"

# Now copy the archive to the webpage dir, and the doc.html as the index.
install -m 0644 -g apache -o apache $FILE_NAME $WEB_PAGE_DIR
echo "Archive copied to web page"

# Now remove some of the comment markers from doc.html
sed "$REMOVE_MARKER" doc.html > "$WEB_PAGE_DIR/index.html"
rm doc.html

chown apache:apache "$WEB_PAGE_DIR/index.html"
echo "Home page index updated"

# Install the script for this computer.
install -m 0755 -g root -o root kdecvs-build /usr/bin
echo "kdecvs-build version $VERSION installed to /usr/bin"
