#!/usr/bin/env bash
# Consider running modTracker within a virtual env if you don't like to install all these
sudo apt-get update
sudo apt-get --yes --force-yes install python python2.7-dev python-pyasn1 python-setuptools python-pip python-dev libxml2-dev libxslt1-dev libffi-dev git screen libxss-dev xvfb firefox flashplugin-installer build-essential strace nano libssl-dev zlib1g-dev libjpeg8-dev

sudo easy_install pip
# 
sudo pip install -r etc/requirements.txt

mkdir bins
mkdir jobs
mkdir tmp
# mkdir etc  # etc dir should be there already
cd etc
wget https://s3.amazonaws.com/alexa-static/top-1m.csv.zip
unzip top-1m.csv.zip
rm top-1m.csv.zip
cd ../bins

rm -rf ff-mod firefox-43.0.4.en-US.linux-x86_64.tar.bz2  # remove old ones, if any
# Don't like downloading a binary? Use the provided patch to build your own Firefox. 
wget https://securehomes.esat.kuleuven.be/~gacar/firefox-43.0.4.en-US.linux-x86_64.tar.bz2
tar xvf firefox-43.0.4.en-US.linux-x86_64.tar.bz2

mv firefox ff-mod
# ./ff-mod/firefox -CreateProfile "ff_prof ~/dev/modCrawler/etc/ff_prof"
timeout 1 mitmdump  # this will create the certs in ~/.mitmproxy

echo "Setting up ptrace permissions, you may need to manually edit ptrace config if you get an error in the next step"
sudo echo 0 |sudo tee /proc/sys/kernel/yama/ptrace_scope
#if the above command fails
# Change the 1 in /proc/sys/kernel/yama/ptrace_scope to 0
echo "Setting ptrace to 0 (more permissive) has serious security implications."
echo "See, https://wiki.ubuntu.com/SecurityTeam/Roadmap/KernelHardening#ptrace_Protection"
