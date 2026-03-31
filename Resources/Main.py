#!/usr/bin/python

import json
import subprocess
import os
import sys
import stat
import tempfile
import zipfile
import shutil
import re
import time
import platform
from distutils.version import LooseVersion
from distutils.dir_util import copy_tree as merge_tree

def get_path_to_me(escape_chars=False):
	path = os.path.dirname(os.path.abspath(sys.argv[0])) + "/"
	if escape_chars:
		return re.sub(r'([^a-zA-Z0-9])', r'\\\1', path)
	else:
		return path

def run_shell(command):
	try:
		process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
		output, error = process.communicate()
		return output.decode('utf-8').strip()
	except Exception as e:
		print("Exception occurred while running shell:", str(e))
		return None

def run_applescript(script):
	try:
		process = subprocess.Popen(['osascript', '-e', script], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
		output, error = process.communicate()
		
		if process.returncode == 0:
			return output.decode('utf-8').strip()
		else:
			print("Error:", error.decode('utf-8').strip())
			return None
	except Exception as e:
		print("Exception occurred while running Applescript:", str(e))
		return None
	
def run_gui_applescript(script):
	# Always use run_gui_applescript() instead of run_applescript() when displaying a GUI.
	# Otherwise, the code will fail on OS X 10.8 and below with error "No user interaction allowed."
	# On these operating systems, osascript cannot create GUIs by itself, it must tell System Events to do so.
	if LooseVersion(platform.mac_ver()[0]) < LooseVersion("10.9"):
		run_applescript('tell application "System Events" to activate')
		return run_applescript('tell application "System Events" to ' + script)
	else:
		return run_applescript(script)
	
def display_list(list, title, prompt):
	applescript_list_string = "{"
	for index in range (len(list)):
		applescript_list_string = applescript_list_string + '"' + str(list[index])
		if index < len(list) - 1:
			applescript_list_string = applescript_list_string + '", '
		else:
			applescript_list_string = applescript_list_string + '"}'
	
	return run_gui_applescript('choose from list ' + applescript_list_string + ' with title "' + title + '" with prompt "' + prompt + '"')
	
def get_path_of_application(bundle_id):
	return run_applescript('tell application "Finder" to get POSIX path of (application file id "' + bundle_id + '" as text)')
	
def is_on_startup_disk(path):
	startup_disk_device_id = os.stat('/').st_dev
	try:
		path_device_id = os.stat(path).st_dev
	except OSError:
		return False
	return path_device_id == startup_disk_device_id

def is_in_trash(path):
	trash_dir = os.path.expanduser('~/.Trash')
	return os.path.commonprefix([os.path.abspath(path), trash_dir]) == trash_dir

def check_github_connection():
	my_path = get_path_to_me(escape_chars=True)
	url = "https://github.com"
	
	# We're using a bundled version of curl and a bundled CA certificate store.
	# This means certificates in Keychain Access will be ignored. This is annoying,
	# but basically required for the downloader to work without Aqua Proxy installed.
	
	command = "{}/curl -Is --cacert {}/cacert.pem {} | head -n 1".format(my_path, my_path, url)
	response = run_shell(command)
	if not response or "200" not in response:
		print(response)
		run_gui_applescript('display alert "Could not connect to Github. Please make sure you are connected to the internet, or try again later." as critical')
		exit()

def get_github_releases(owner, repo, limit=30):
	my_path = get_path_to_me(escape_chars=True)
	url = 'https://api.github.com/repos/{}/{}/releases?per_page={}'.format(owner, repo, limit)
	command = "{}/curl --cacert {}/cacert.pem -s {}".format(my_path, my_path, url)
	response = run_shell(command)
	if response:
		releases = json.loads(response)
		return releases
	else:
		print('Failed to retrieve releases')
		return None

def download_firefox_contents_to_temporary_directory(download_url):
	temp_file_path = tempfile.mktemp()
	
	try:
		my_path = get_path_to_me(escape_chars=True)
		command = "{}/curl --cacert {}/cacert.pem -L {} -o {}".format(my_path, my_path, download_url, temp_file_path)
		run_shell(command)
		
		run_shell("hdiutil attach -nobrowse -plist " + temp_file_path)
		temp_dir = tempfile.mkdtemp()
		shutil.copytree("/Volumes/Momiji/Momiji.app/Contents/", os.path.join(temp_dir, 'Contents'))
		
		run_shell('hdiutil detach "/Volumes/Momiji"')
		os.remove(temp_file_path)
		return os.path.join(temp_dir, 'Contents')
		
	except Exception as e:
		run_gui_applescript('display alert "Error downloading file: ' + str(e) + '" as critical')
		exit()




# MAIN SCRIPT START

check_github_connection()

releases = get_github_releases("aobaharuki2005", "momiji-web-browser", 10)

release_strings = []
for release in releases:
	release_strings.append(release["tag_name"])

selected_build_str = display_list(release_strings, "Momiji Downloader", "Choose a version of Momiji to install.")

#Find index of selected_build_str
for release in releases:
	if release["tag_name"] == selected_build_str:
		selected_build = release

download_url = selected_build["assets"][0]["browser_download_url"]
temp_directory = download_firefox_contents_to_temporary_directory(download_url)

# Copy preferred defaults
shutil.copytree(get_path_to_me() + "/defaults", temp_directory + "/Resources/defaults")
shutil.copy2(get_path_to_me() + "/firefox.cfg", temp_directory + "/Resources/")

# Copy preferred icons
shutil.copy2(get_path_to_me() + "/firefox.icns", temp_directory + "/Resources/")
shutil.copy2(get_path_to_me() + "/document.icns", temp_directory + "/Resources/")

# Copy FirefoxModifier.dylib and inject into binary
shutil.copy2(get_path_to_me() + "/FirefoxModifier.dylib", temp_directory + "/Frameworks/")
run_shell(get_path_to_me(escape_chars=True) + "/insert_dylib --inplace --strip-codesig --all-yes @executable_path/../Frameworks/FirefoxModifier.dylib " + temp_directory + "/MacOS/firefox")

# Copy libMacportsLegacySystem.B.dylib and rewrite all MacOS binaries to use it
shutil.copy2(get_path_to_me() + "/libMacportsLegacySystem.B.dylib", temp_directory + "/Frameworks/")
run_shell("install_name_tool -change /usr/lib/libSystem.B.dylib @executable_path/../Frameworks/libMacportsLegacySystem.B.dylib " + temp_directory + "/MacOS/libgkcodecs.dylib")

# Codesign everything
for root, dirs, files in os.walk(temp_directory):
	for file in files:
		file_path = os.path.join(root, file)
		run_shell(get_path_to_me(escape_chars=True) + "/jtool2 --sign --inplace " + file_path)

firefox_path = get_path_of_application("org.mozilla.momiji")
if not firefox_path or not is_on_startup_disk(firefox_path) or is_in_trash(firefox_path):
	firefox_path = run_gui_applescript('get POSIX path of (choose folder with prompt "Where would you like to save the Momiji app?" default location "Applications") as text') + "/Momiji.app"

shutil.rmtree(firefox_path + "/Contents", ignore_errors=True)
shutil.copytree(temp_directory, firefox_path + "/Contents")
time.sleep(1)
subprocess.Popen(["touch", firefox_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
subprocess.Popen(["chmod", "-R", "755", firefox_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
shutil.rmtree(temp_directory)



# POST INSTALL SETUP

# Lion CoreText Fix
if LooseVersion(platform.mac_ver()[0]) < LooseVersion("10.8") and not os.path.exists("/System/Library/Frameworks/CoreText.framework"):
	run_gui_applescript('do shell script "sudo ln -s /System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/CoreText.framework /System/Library/Frameworks/CoreText.framework" with administrator privileges')

profiles_dir = os.path.expanduser("~/Library/Application Support/Firefox/Profiles/")
if not os.path.exists(profiles_dir):
	# No Firefox profile exists yet. Make one.
	devnull = open(os.devnull, 'w')
	firefox_bin = os.path.join(firefox_path, "Contents", "MacOS", "firefox")
	process = subprocess.Popen([firefox_bin, "-headless"], stdout=devnull, stderr=devnull)
	time.sleep(5)
	process.kill()
	process.wait()
	devnull.close()
	
profiles = [a for a in os.listdir(profiles_dir) if os.path.isdir(os.path.join(profiles_dir, a))]
for profile in profiles:
	# Copy extensions
	extensions_dir = os.path.join(profiles_dir, profile) + "/extensions"
	if not os.path.exists(extensions_dir):
		os.makedirs(extensions_dir)
	merge_tree(get_path_to_me() + "/extensions", extensions_dir)
		
	# Widevine
	if LooseVersion(platform.mac_ver()[0]) >= LooseVersion("10.9"):
		openwv_dir = os.path.join(profiles_dir, profile) + "/gmp-widevinecdm/openwv"
		if not os.path.exists(openwv_dir):
			os.makedirs(openwv_dir)
		shutil.copy2(get_path_to_me() + "/openwv/libwidevinecdm.dylib", openwv_dir)
		shutil.copy2(get_path_to_me() + "/openwv/manifest.json", openwv_dir)

	#UserChrome
	chrome_dir = os.path.join(profiles_dir, profile) + "/chrome"
	if not os.path.exists(chrome_dir):
		os.makedirs(chrome_dir)
	shutil.copy2(get_path_to_me() + "/userChrome.css", chrome_dir)
	
run_gui_applescript('display dialog "Your new copy of Momiji has been installed." buttons {"OK"}')