-- echo-target.scpt — macOS echo target for LatencyBench keystroke-echo mode.
--
-- This is an AppleScript that creates a Cocoa window with a huge digit on a
-- black background. Each digit keypress (0–9) flips the displayed digit so
-- the bench can detect the pixel change.
--
-- Run on the target Mac being shared via Screen Sharing:
--   osascript Scripts/echo-target.scpt
--
-- Quit with ⌘Q.
--
-- The window covers the full main screen so framebuffer coordinates and the
-- script's text rect are easy to line up. The bench should be invoked with
-- --echo-region matching the central rectangle drawn here.

use AppleScript version "2.4"
use scripting additions
use framework "AppKit"
use framework "Foundation"

property NSApp : current application's NSApplication's sharedApplication()
property currentDigit : "0"
property labelView : missing value

on run
  -- Build a borderless black window covering the main screen.
  set screenFrame to current application's NSScreen's mainScreen's frame()
  set styleMask to (current application's NSWindowStyleMaskBorderless)
  set theWindow to (current application's NSWindow's alloc()'s ¬
    initWithContentRect:screenFrame styleMask:styleMask ¬
    backing:(current application's NSBackingStoreBuffered) defer:false)
  theWindow's setLevel:(current application's NSStatusWindowLevel)
  theWindow's setBackgroundColor:(current application's NSColor's blackColor())
  theWindow's setOpaque:true

  set centerRect to {{(screenFrame's |size|'s width) / 2 - 240, (screenFrame's |size|'s height) / 2 - 240}, {480, 480}}
  set labelView to (current application's NSTextField's alloc()'s initWithFrame:centerRect)
  labelView's setBezeled:false
  labelView's setDrawsBackground:false
  labelView's setEditable:false
  labelView's setSelectable:false
  labelView's setAlignment:(current application's NSTextAlignmentCenter)
  labelView's setTextColor:(current application's NSColor's whiteColor())
  labelView's setFont:(current application's NSFont's systemFontOfSize:400 weight:0.9)
  labelView's setStringValue:currentDigit

  theWindow's contentView's addSubview:labelView
  theWindow's makeKeyAndOrderFront:(missing value)

  -- Poll for key presses on the foreground app.
  repeat
    delay 0.02
    set pressedDigit to readDigitFromEvents()
    if pressedDigit is not missing value then
      set currentDigit to pressedDigit
      labelView's setStringValue:currentDigit
    end if
  end repeat
end run

on readDigitFromEvents()
  -- AppleScript polling: NSEvent.nextEventMatchingMask is awkward but works.
  set keyEvent to NSApp's nextEventMatchingMask:(current application's NSEventMaskKeyDown) untilDate:(missing value) inMode:(current application's NSDefaultRunLoopMode) dequeue:true
  if keyEvent is missing value then return missing value
  set chars to (keyEvent's |characters|()) as text
  if (count of chars) is 0 then return missing value
  set firstChar to text 1 thru 1 of chars
  if firstChar is in {"0","1","2","3","4","5","6","7","8","9"} then return firstChar
  return missing value
end readDigitFromEvents
