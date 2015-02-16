root = exports ? window

currentVersion = Utils.getCurrentVersion()

keyQueue = "" # Queue of keys typed
validFirstKeys = {}
singleKeyCommands = []
focusedFrame = null
framesForTab = {}

# Keys are either literal characters, or "named" - for example <a-b> (alt+b), <left> (left arrow) or <f12>
# This regular expression captures two groups: the first is a named key, the second is the remainder of
# the string.
namedKeyRegex = /^(<(?:[amc]-.|(?:[amc]-)?[a-z0-9]{2,5})>)(.*)$/

chrome.commands.onCommand.addListener (command) ->
  chrome.extension.onConnect.addListener((port, name) ->
    senderTabId = if port.sender.tab then port.sender.tab.id else null
  
    if (portHandlers[port.name])
      port.onMessage.addListener(portHandlers[port.name])
  )
  
  chrome.extension.onRequest.addListener((request, sender, sendResponse) ->
    if (sendRequestHandlers[request.handler])
      sendResponse(sendRequestHandlers[request.handler](request, sender))
    # Ensure the sendResponse callback is freed.
    return false)
  
  chrome.extension.onMessage.addListener((request, sender, sendResponse) ->
    if (sendRequestHandlers[request.handler])
      sendResponse(sendRequestHandlers[request.handler](request, sender))
    # Ensure the sendResponse callback is freed.
    return false)

  #
  # Used by the content scripts to get their full URL. This is needed for URLs like "view-source:http:# .."
  # because window.location doesn't know anything about the Chrome-specific "view-source:".
  #
  getCurrentTabUrl = (request, sender) -> sender.tab.url
  
  #
  # Checks the user's preferences in local storage to determine if Vimium is enabled for the given URL.
  #
  isEnabledForUrl = (request) ->
    # excludedUrls are stored as a series of URL expressions separated by newlines.
    excludedUrls = Settings.get("excludedUrls").split("\n")
    isEnabled = true
    for url in excludedUrls
      # The user can add "*" to the URL which means ".*"
      regexp = new RegExp("^" + url.replace(/\*/g, ".*") + "$")
      isEnabled = false if request.url.match(regexp)
    { isEnabledForUrl: isEnabled }
  
  #
  # Opens the url in the current tab.
  #
  openUrlInCurrentTab = (request) ->
    chrome.tabs.getSelected(null,
      (tab) -> chrome.tabs.update(tab.id, { url: Utils.convertToUrl(request.url) }))
  
  #
  # Opens request.url in new tab and switches to it if request.selected is true.
  #
  openUrlInNewTab = (request) ->
    chrome.tabs.getSelected(null, (tab) ->
      chrome.tabs.create({ url: Utils.convertToUrl(request.url), index: tab.index + 1, selected: true }))
  
  openUrlInIncognito = (request) ->
    chrome.windows.create({ url: Utils.convertToUrl(request.url), incognito: true})
  
  #
  # Copies some data (request.data) to the clipboard.
  #
  copyToClipboard = (request) -> Clipboard.copy(request.data)
  
  #
  # Selects the tab with the ID specified in request.id
  #
  selectSpecificTab = (request) ->
    chrome.tabs.get(request.id, (tab) ->
      chrome.windows.update(tab.windowId, { focused: true })
      chrome.tabs.update(request.id, { selected: true }))
  
  #
  # Used by the content scripts to get settings from the local storage.
  #
  handleSettings = (args, port) ->
    if (args.operation == "get")
      value = Settings.get(args.key)
      port.postMessage({ key: args.key, value: value })
    else # operation == "set"
      Settings.set(args.key, args.value)
  
  refreshCompleter = (request) -> completers[request.name].refresh()
  
  whitespaceRegexp = /\s+/
  filterCompleter = (args, port) ->
    queryTerms = if (args.query == "") then [] else args.query.split(whitespaceRegexp)
    completers[args.name].filter(queryTerms, (results) -> port.postMessage({ id: args.id, results: results }))
  
  getCurrentTimeInSeconds = -> Math.floor((new Date()).getTime() / 1000)
  
  chrome.tabs.onSelectionChanged.addListener (tabId, selectionInfo) ->
    if (selectionChangedHandlers.length > 0)
      selectionChangedHandlers.pop().call()
  
  repeatFunction = (func, totalCount, currentCount, frameId) ->
    if (currentCount < totalCount)
      func(
        -> repeatFunction(func, totalCount, currentCount + 1, frameId),
        frameId)
  
  # Start action functions
  
  # These are commands which are bound to keystroke which must be handled by the background page. They are
  # mapped in commands.coffee.
  BackgroundCommands =
    openCopiedUrlInCurrentTab: (request) -> openUrlInCurrentTab({ url: Clipboard.paste() })
    openCopiedUrlInNewTab: (request) -> openUrlInNewTab({ url: Clipboard.paste() })
  
  # Selects a tab before or after the currently selected tab.
  # - direction: "next", "previous", "first" or "last".
  selectTab = (callback, direction) ->
    chrome.tabs.getAllInWindow(null, (tabs) ->
      return unless tabs.length > 1
      chrome.tabs.getSelected(null, (currentTab) ->
        switch direction
          when "next"
            toSelect = tabs[(currentTab.index + 1 + tabs.length) % tabs.length]
          when "previous"
            toSelect = tabs[(currentTab.index - 1 + tabs.length) % tabs.length]
          when "first"
            toSelect = tabs[0]
          when "last"
            toSelect = tabs[tabs.length - 1]
        selectionChangedHandlers.push(callback)
        chrome.tabs.update(toSelect.id, { selected: true })))
  
  # Updates the browserAction icon to indicated whether Vimium is enabled or disabled on the current page.
  # Also disables Vimium if it is currently enabled but should be disabled according to the url blacklist.
  # This lets you disable Vimium on a page without needing to reload.
  #
  # Three situations are considered:
  # 1. Active tab is disabled -> disable icon
  # 2. Active tab is enabled and should be enabled -> enable icon
  # 3. Active tab is enabled but should be disabled -> disable icon and disable vimium
  updateActiveState = (tabId) ->
    enabledIcon = "icons/browser_action_enabled.png"
    disabledIcon = "icons/browser_action_disabled.png"
    chrome.tabs.get(tabId, (tab) ->
      # Default to disabled state in case we can't connect to Vimium, primarily for the "New Tab" page.
      chrome.browserAction.setIcon({ path: disabledIcon })
      chrome.tabs.sendRequest(tabId, { name: "getActiveState" }, (response) ->
        isCurrentlyEnabled = (response? && response.enabled)
        shouldBeEnabled = isEnabledForUrl({url: tab.url}).isEnabledForUrl
  
        if (isCurrentlyEnabled)
          if (shouldBeEnabled)
            chrome.browserAction.setIcon({ path: enabledIcon })
          else
            chrome.browserAction.setIcon({ path: disabledIcon })
            chrome.tabs.sendRequest(tabId, { name: "disableVimium" })
        else
          chrome.browserAction.setIcon({ path: disabledIcon })))
  
  splitKeyIntoFirstAndSecond = (key) ->
    if (key.search(namedKeyRegex) == 0)
      { first: RegExp.$1, second: RegExp.$2 }
    else
      { first: key[0], second: key.slice(1) }
  
  getActualKeyStrokeLength = (key) ->
    if (key.search(namedKeyRegex) == 0)
      1 + getActualKeyStrokeLength(RegExp.$2)
    else
      key.length
  
  populateValidFirstKeys = ->
    for key of Commands.keyToCommandRegistry
      if (getActualKeyStrokeLength(key) == 2)
        validFirstKeys[splitKeyIntoFirstAndSecond(key).first] = true
  
  populateSingleKeyCommands = ->
    for key of Commands.keyToCommandRegistry
      if (getActualKeyStrokeLength(key) == 1)
        singleKeyCommands.push(key)
  
  splitKeyQueue = (queue) ->
    match = /([1-9][0-9]*)?(.*)/.exec(queue)
    count = parseInt(match[1], 10)
    command = match[2]
  
    { count: count, command: command }
  
  handleKeyDown = (request, port) ->
    key = request.keyChar
    if (key == "<ESC>")
      console.log("clearing keyQueue")
      keyQueue = ""
    else
      console.log("checking keyQueue: [", keyQueue + key, "]")
      keyQueue = checkKeyQueue(keyQueue + key, port.sender.tab.id, request.frameId)
      console.log("new KeyQueue: " + keyQueue)
  
  checkKeyQueue = (keysToCheck, tabId, frameId) ->
    splitHash = splitKeyQueue(keysToCheck)
    command = splitHash.command
    count = splitHash.count
  
    return keysToCheck if command.length == 0
    count = 1 if isNaN(count)
  
    if (Commands.keyToCommandRegistry[command])
      registryEntry = Commands.keyToCommandRegistry[command]
  
      if !registryEntry.isBackgroundCommand
        chrome.tabs.sendRequest(tabId,
          name: "executePageCommand",
          command: registryEntry.command,
          frameId: frameId,
          count: count,
          passCountToFunction: registryEntry.passCountToFunction)
      else
        if registryEntry.passCountToFunction
          BackgroundCommands[registryEntry.command](count)
        else if registryEntry.noRepeat
          BackgroundCommands[registryEntry.command]()
        else
          repeatFunction(BackgroundCommands[registryEntry.command], count, 0, frameId)
  
      newKeyQueue = ""
    else if (getActualKeyStrokeLength(command) > 1)
      splitKey = splitKeyIntoFirstAndSecond(command)
  
      # The second key might be a valid command by its self.
      if (Commands.keyToCommandRegistry[splitKey.second])
        newKeyQueue = checkKeyQueue(splitKey.second, tabId, frameId)
      else
        newKeyQueue = (if validFirstKeys[splitKey.second] then splitKey.second else "")
    else
      newKeyQueue = (if validFirstKeys[command] then count.toString() + command else "")
  
    newKeyQueue
  
  registerFrame = (request, sender) ->
    unless framesForTab[sender.tab.id]
      framesForTab[sender.tab.id] = { frames: [] }
  
    if (request.is_top)
      focusedFrame = request.frameId
      framesForTab[sender.tab.id].total = request.total
  
    framesForTab[sender.tab.id].frames.push({ id: request.frameId, area: request.area })
  
  handleFrameFocused = (request, sender) -> focusedFrame = request.frameId
  
  # Port handler mapping
  portHandlers =
    keyDown: handleKeyDown,
    settings: handleSettings,
    filterCompleter: filterCompleter
  
  sendRequestHandlers =
    getCurrentTabUrl: getCurrentTabUrl,
    openUrlInNewTab: openUrlInNewTab,
    openUrlInIncognito: openUrlInIncognito,
    openUrlInCurrentTab: openUrlInCurrentTab,
    registerFrame: registerFrame,
    frameFocused: handleFrameFocused,
    copyToClipboard: copyToClipboard,
    isEnabledForUrl: isEnabledForUrl,
  
  # Convenience function for development use.
  window.runTests = -> open(chrome.extension.getURL('tests/dom_tests/dom_tests.html'))
  
  #
  # Initialize key mappings
  #
  Commands.clearKeyMappingsAndSetDefaults()
  
  chrome.tabs.executeScript(null, { file: "lib/utils.js" })
  chrome.tabs.executeScript(null, { file: "lib/keyboard_utils.js" })
  chrome.tabs.executeScript(null, { file: "lib/dom_utils.js" })
  chrome.tabs.executeScript(null, { file: "lib/handler_stack.js" })
  chrome.tabs.executeScript(null, { file: "lib/clipboard.js" })
  chrome.tabs.executeScript(null, { file: "content_scripts/link_hints.js" })
  chrome.tabs.executeScript(null, { file: "content_scripts/scroller.js" })
  chrome.tabs.executeScript(null, { file: "content_scripts/vimium_frontend.js" })
  chrome.tabs.insertCSS(null, { file: "content_scripts/vimium.css" })

  chrome.tabs.onActiveChanged.addListener (tabId, selectInfo) -> updateActiveState(tabId)

  mode = if command == 'activate-link-hints-new-tab' then 'activateModeToOpenInNewTab' else 'activateMode'
  # TODO: Change this to a message to the content scripts
  chrome.tabs.executeScript({ code: "root.LinkHints.init(); root.LinkHints." + mode + "(); console.log('activated!');" })
