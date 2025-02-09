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
			return output.strip()
		else:
			print("Error:", error.strip())
			return None
	except Exception as e:
		print("Exception occurred while running Applescript:", str(e))
		return None
	
def display_list(list, title, prompt):
	applescript_list_string = "{"
	for index in range (len(list)):
		applescript_list_string = applescript_list_string + '"' + str(list[index])
		if index < len(list) - 1:
			applescript_list_string = applescript_list_string + '", '
		else:
			applescript_list_string = applescript_list_string + '"}'
	
	return run_applescript('choose from list ' + applescript_list_string + ' with title "' + title + '" with prompt "' + prompt + '"')
	
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
	url = "https://github.com"
	
	# All uses of curl in this code include the -k flag, disabling SSL certificate verification.
	# This isn't great for downloading a sensitive app like a web browser.
	# However, because we need to work on old systems, I don't know what else to do!
	
	# To work around SSL incompatibilities, we are shipping our own copy of curl built against OpenSSL.
	# In order to verify certificates, we would need to also ship our own certificate store.
	# However, this would break for users who have actually done the right thing and installed an SSL mitm proxy,
	# which in the general case is the best way to make SSL work on legacy OS X.
	
	# Note that if a proxy is installed, the proxy will hopefully perform certificate verification even if curl doesn't.
	
	command = "{}/curl -Isk {} | head -n 1".format(get_path_to_me(escape_chars=True), url)
	response = run_shell(command)
	if not response or "200" not in response:
		print(response)
		run_applescript('display alert "Could not connect to Github. Please make sure you are connected to the internet, or try again later." as critical')
		exit()

def get_github_releases(owner, repo, limit=30):
	url = 'https://api.github.com/repos/{}/{}/releases?per_page={}'.format(owner, repo, limit)
	command = "{}/curl -sk {}".format(get_path_to_me(escape_chars=True), url)
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
		command = "{}/curl -k -L {} -o {}".format(get_path_to_me(escape_chars=True), download_url, temp_file_path)
		run_shell(command)
		
		temp_dir = tempfile.mkdtemp()
		with zipfile.ZipFile(temp_file_path, 'r') as zip_ref:
			for member in zip_ref.infolist():
				if member.filename.startswith('Firefox.app/Contents/'):
					member_path = member.filename.split('/', 1)[-1]
					target_path = os.path.join(temp_dir, member_path)
					
					if member.filename.endswith('/'):
						if not os.path.exists(target_path):
							os.makedirs(target_path)
					else:
						with open(target_path, 'wb') as out_file:
							out_file.write(zip_ref.read(member))
							
						if member.external_attr >> 16 & stat.S_IXUSR:
							st = os.stat(target_path)
							os.chmod(target_path, st.st_mode | stat.S_IEXEC)
		
		os.remove(temp_file_path)
		return os.path.join(temp_dir, 'Contents')
	except Exception as e:
		print('Error downloading file:', e)
		exit()

check_github_connection()

releases = get_github_releases("i3roly", "firefox-dynasty", 10)

release_strings = []
for release in releases:
	release_strings.append(release["tag_name"])

selected_build_str = display_list(release_strings, "Firefox Downloader", "Choose a version of Firefox Dynasty to install.")

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

# Codesign everything
for root, dirs, files in os.walk(temp_directory):
	for file in files:
		file_path = os.path.join(root, file)
		run_shell(get_path_to_me(escape_chars=True) + "/jtool2 --sign --inplace " + file)

firefox_path = get_path_of_application("org.mozilla.firefox")
if not firefox_path or not is_on_startup_disk(firefox_path) or is_in_trash(firefox_path):
	firefox_path = run_applescript('get POSIX path of (choose folder with prompt "Where would you like to save the Firefox app?" default location "Applications") as text') + "/Firefox.app"

shutil.rmtree(firefox_path + "/Contents", ignore_errors=True)
shutil.copytree(temp_directory, firefox_path + "/Contents")
time.sleep(1)
run_shell("chmod -R 755 " + firefox_path)
run_shell("touch " + firefox_path)

shutil.rmtree(temp_directory)
run_applescript('display dialog "Your new copy of Firefox Dynasty has been installed." buttons {"OK"}')
