function modifyUserAgent(details) {
	const headers = details.requestHeaders;
	for (let i = 0; i < headers.length; i++) {
		if (headers[i].name === 'User-Agent') {
			headers[i].value = headers[i].value.replace("Mac OS X 10.15;", 'Mac OS X 10.9;');
			break;
		}
	}
	return { requestHeaders: headers };
}

browser.webRequest.onBeforeSendHeaders.addListener(
	modifyUserAgent,
	{
		urls: [
			"*://fonts.googleapis.com/*",
			"*://fonts.gstatic.com/*"
		]
	},
	["blocking", "requestHeaders"]
);