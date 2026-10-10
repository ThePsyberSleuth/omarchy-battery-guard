import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons as Commons
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "thepsybersleuth.battery-guard"
  ipcTarget: "omarchy.power"
  manageIpc: false

  property var batteryInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  property var snapshot: ({ batteries: [] })
  property string selectedBattery: ""
  property string statusError: ""
  property string actionMessage: ""
  property int customLimit: 80
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("battery-control.py").toString().replace(/^file:\/\//, ""))
  readonly property var batteryData: {
    var rows = snapshot.batteries || []
    for (var i = 0; i < rows.length; i++)
      if (rows[i].name === selectedBattery) return rows[i]
    return rows.length ? rows[0] : ({})
  }

  function metric(value, unit) {
    return value === null || value === undefined ? "Unavailable" : String(value) + unit
  }

  function updateChargeStatus(raw) {
    try {
      var result = JSON.parse(raw)
      if (!result.ok) { statusError = result.error; return }
      snapshot = result
      statusError = result.manager_error || ""
      if (!selectedBattery && result.batteries.length) {
        selectedBattery = result.batteries[0].name
        if (result.batteries[0].end !== null) customLimit = result.batteries[0].end
      }
    } catch (e) { statusError = "Cannot read charge status: " + e }
  }

  function setLimit(limit) {
    if (actionProc.running || !batteryData.can_limit) return
    customLimit = limit
    actionMessage = "Authorize the charge-limit change in the system dialog."
    actionProc.command = ["/usr/bin/python3", helper, "set", batteryData.name, String(limit)]
    actionProc.running = true
  }

  function topUp() { setLimit(100) }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Commons.Color.foreground
  }

  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return
    if (!statusProc.running) statusProc.running = true
    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || profileActionProc.running || actionProc.running) return
    actionMessage = ""
    profileActionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    profileActionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  ShellIpc {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: { if (batteryPresent) refresh(); else close() }

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: statusProc
    command: ["/usr/bin/python3", root.helper, "status"]
    stdout: StdioCollector { onStreamFinished: root.updateChargeStatus(text) }
    stderr: StdioCollector { onStreamFinished: if (text.trim()) root.statusError = text.trim() }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          root.actionMessage = result.ok ? result.message : "Not applied: " + result.error
        } catch (e) { root.actionMessage = "No valid response from charge-limit helper." }
      }
    }
    stderr: StdioCollector { onStreamFinished: if (text.trim()) root.actionMessage = text.trim() }
    onExited: root.refresh()
  }

  Process {
    id: profileActionProc
    stderr: StdioCollector { onStreamFinished: if (text.trim()) root.actionMessage = text.trim() }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.actionMessage) root.actionMessage = "Power profile change failed."
      root.refresh()
    }
  }

  Timer { interval: root.opened ? 5000 : 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: Style.duration(180); easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: Style.duration(260); easing.type: Easing.InQuad
    }
  }

  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: "Battery Guard · Limit: " + root.metric(root.batteryData.end, "%")
    function nudgeIcon() {
      if (!Style.reduceMotion) iconNudge.restart()
    }
    onTooltipHoveredChanged: if (tooltipHovered) nudgeIcon()

    SequentialAnimation {
      id: iconNudge
      NumberAnimation { target: button; property: "textRotation"; from: 0; to: -5; duration: Style.duration(90); easing.type: Easing.OutCubic }
      NumberAnimation { target: button; property: "textRotation"; to: 3; duration: Style.duration(110); easing.type: Easing.InOutSine }
      NumberAnimation { target: button; property: "textRotation"; to: 0; duration: Style.duration(100); easing.type: Easing.OutCubic }
    }
    Connections {
      target: Style
      function onReduceMotionChanged() {
        if (Style.reduceMotion) {
          iconNudge.stop()
          button.textRotation = 0
        }
      }
    }
    onPressed: function(b) {
      if (!root.batteryPresent) return
      button.nudgeIcon()
      if (b === Qt.LeftButton) root.toggle()
      else if (b === Qt.RightButton) root.togglePercentage()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }
        }

        // ---------- Battery progress bar with threshold notch ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: Style.duration(220) } }

            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened && !Style.reduceMotion
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }

          // Threshold marker notch
          Rectangle {
            visible: root.batteryData.end !== null && root.batteryData.end !== undefined
            width: 3
            height: barTrack.height + 4
            anchors.verticalCenter: barTrack.verticalCenter
            x: Math.max(0, Math.min(barTrack.width - 3, (barTrack.width * ((root.batteryData.end || 0) / 100.0)) - 1.5))
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.9)
            radius: 1
          }
        }

        // ---------- Native Stats ----------
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? root.metric(root.batteryData.end, "%") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Battery Guard / Charge Limiter Section ----------
        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(sectionHeader.implicitHeight, sectionCap.implicitHeight)
            PanelSectionHeader {
              id: sectionHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "CHARGE LIMITER"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }
            Text {
              id: sectionCap
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Limit: " + root.metric(root.batteryData.end, "%")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              opacity: 0.85
            }
          }

          // Quick Presets: 60%, 70%, 80%, 100%
          Row {
            id: presetRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * 3) / 4

            Button {
              width: presetRow.cellWidth
              text: "60%"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              enabled: root.batteryData.can_limit === true && !actionProc.running
              active: root.batteryData.end === 60
              onClicked: root.setLimit(60)
            }

            Button {
              width: presetRow.cellWidth
              text: "70%"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              enabled: root.batteryData.can_limit === true && !actionProc.running
              active: root.batteryData.end === 70
              onClicked: root.setLimit(70)
            }

            Button {
              width: presetRow.cellWidth
              text: "80%"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              enabled: root.batteryData.can_limit === true && !actionProc.running
              active: root.batteryData.end === 80
              onClicked: root.setLimit(80)
            }

            Button {
              width: presetRow.cellWidth
              text: "100%"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              enabled: root.batteryData.can_limit === true && !actionProc.running
              active: root.batteryData.end === 100
              onClicked: root.setLimit(100)
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - Style.space(8)) / 2
              text: "Sailing Mode"
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              enabled: false
            }

            Button {
              width: (parent.width - Style.space(8)) / 2
              text: "Top Up (100%)"
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              enabled: root.batteryData.can_limit === true && !actionProc.running
              active: root.batteryData.end === 100
              onClicked: root.topUp()
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Rectangle {
              width: (parent.width - Style.space(8)) / 2
              height: applyButton.implicitHeight
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
              border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.6)
              TextInput {
                id: limitInput
                anchors.fill: parent
                anchors.margins: Style.space(6)
                text: String(root.customLimit)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: TextInput.AlignHCenter
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                maximumLength: 3
                validator: IntValidator { bottom: 50; top: 100 }
                enabled: root.batteryData.can_limit === true && !actionProc.running
                onAccepted: if (acceptableInput) root.setLimit(Number(text))
              }
            }
            Button {
              id: applyButton
              width: (parent.width - Style.space(8)) / 2
              text: actionProc.running ? "Authorizing…" : "Apply limit"
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              enabled: limitInput.acceptableInput && root.batteryData.can_limit === true && !actionProc.running
              onClicked: root.setLimit(Number(limitInput.text))
            }
          }

          InfoPair { label: "Policy"; value: root.snapshot.manager || "Driver only" }
          Text {
            width: parent.width
            visible: text.length > 0
            text: root.statusError || root.actionMessage
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            text: (root.batteryData.can_start ? "Sailing policy is not implemented." : "This driver has no start threshold; Sailing Mode is unavailable.")
              + " Temperature is monitored only. Top Up sets 100% until you restore your preferred limit."
            color: root.bar.foreground
            opacity: 0.65
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Telemetry
          Row {
            width: parent.width
            spacing: Style.space(20)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair { label: "Charge/full"; value: root.metric(root.batteryData.charge_ratio, "%") }
              InfoPair { label: "Health"; value: root.metric(root.batteryData.health, "%") }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair { label: "Battery Temp"; value: root.metric(root.batteryData.temperature, " °C") }
              InfoPair { label: "Battery Power"; value: root.metric(root.batteryData.watts, " W") }
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                enabled: !profileActionProc.running && !actionProc.running
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    id: pairRow
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item {
      width: Math.max(0, pairRow.width - pairRow.children[0].implicitWidth - pairRow.children[2].implicitWidth - pairRow.spacing * 2)
      height: 1
    }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
