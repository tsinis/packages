// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
//  CUIImagePickerController.m
//
//  Created by Roman Cinis on 20.11.2025
//  Copyright 2025 Roman Cinis. All rights reserved.
//

#import "./include/image_picker_ios/CUIImagePickerController.h"

#import <AVFoundation/AVFoundation.h>
#import <sys/utsname.h>

// AVCaptureSessionInterruptionReasonKey values logged by
// [logCaptureSessionInterrupted:]. Reference for triaging "camera goes black"
// reports in Sentry / device logs.
//
//   1  VideoDeviceNotAvailableInBackground
//        App backgrounded or screen locked while camera was active.
//   2  AudioDeviceInUseByAnotherClient
//        Another process holds the audio input (e.g. active phone call).
//   3  VideoDeviceInUseByAnotherClient
//        Another process holds the camera (e.g. FaceTime, another app).
//   4  VideoDeviceNotAvailableWithMultipleForegroundApps
//        iPad Split View / Slide Over — camera denied to secondary app.
//   5  VideoDeviceNotAvailableDueToSystemPressure  (iOS 9+)
//        Thermal, memory, or power constraint forced the session down.
//
// Expected benign pattern: [reason=1] followed by an "interruption ended" log
// ~seconds later as the user unlocks / foregrounds. An interrupted event
// without a matching end, or reasons 3 / 5, indicate a session the OS did not
// resume — the likely cause of the ~1% black-preview reports.
// See: AVCaptureSessionInterruptionReason in <AVFoundation/AVCaptureSession.h>.

// Hardware model identifier (e.g. "iPhone14,2"). More useful than
// [UIDevice.model] (which only returns "iPhone") for triaging device-specific
// reports in crash logs / Sentry breadcrumbs.
static NSString *IPIDeviceModelIdentifier(void) {
  struct utsname systemInfo;
  if (uname(&systemInfo) != 0) return @"unknown";
  NSString *machine = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
  return machine.length > 0 ? machine : @"unknown";
}

// Implementation of the [CUIImagePickerController] class.
@implementation CUIImagePickerController {
  BOOL _hasRegisteredObserver;
  // Authoritative intent: YES when the user is in capture mode and the overlay
  // should be on screen; NO during preview or before the initial show delay has
  // elapsed. System-driven hides (e.g. app suspension) must not mutate this.
  BOOL _shouldBeVisible;
}

// [shouldAutorotate] is deprecated on iOS 16+, but is used for older systems.
- (BOOL)shouldAutorotate {
  return NO;
}

// Same as [shouldAutorotate] it's deprecated on iOS 16+, but is used for older systems.
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
  return (interfaceOrientation == UIInterfaceOrientationLandscapeLeft ||
          interfaceOrientation == UIInterfaceOrientationLandscapeRight);
}

// The interface orientations that the view controller supports.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskPortrait;
}

// The preferred orientation to use in camera view (default to portrait)
// View will be rotated to this one if it's not in the portrait mode already.
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
  return UIInterfaceOrientationPortrait;
}

- (void)hideCameraOverlay {
  _shouldBeVisible = NO;
  [self.cameraOverlayView setHidden:YES];
}

- (void)showCameraOverlay {
  _shouldBeVisible = YES;
  [self.cameraOverlayView setHidden:NO];
}

// Transient hide triggered by the system (app suspension / screen lock). Leaves
// [_shouldBeVisible] untouched so [restoreCameraOverlayVisibility] can return
// the overlay to the correct state on foreground.
- (void)temporarilyHideCameraOverlay {
  [self.cameraOverlayView setHidden:YES];
}

- (void)restoreCameraOverlayVisibility {
  [self.cameraOverlayView setHidden:!_shouldBeVisible];
}

/// [self.cameraOverlayView.subviews.count] is only available at this moment.
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // [self.cameraOverlayView] is only available when [sourceType] is the camera.
  if (self.sourceType != UIImagePickerControllerSourceTypeCamera) return;
  // If camera overlay has some subviews -> it should be our [OverlayView].
  if (self.cameraOverlayView.subviews.count < 1) return;
  // Only register observer once to prevent duplicate registrations.
  if (_hasRegisteredObserver) return;
  _hasRegisteredObserver = YES;
  // So we have a camera overlay at this moment, let's show it after small delay.
  [self performSelector:@selector(showCameraOverlay) withObject:nil afterDelay:1.2];

  // One log line per camera session to correlate user reports (iOS version +
  // hardware model) with any interruption events logged below. Intentionally
  // cheap: single [NSLog], no state, no UI.
  NSLog(@"[image_picker_ios] camera opened: iOS=%@ device=%@",
        UIDevice.currentDevice.systemVersion, IPIDeviceModelIdentifier());

  // Register explicit observers per notification name rather than a [name:nil]
  // wildcard — avoids dispatching every process-wide notification through our
  // handler and makes the listened-for set self-documenting.
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(handleWillCapturePhoto)
                 name:@"Recorder_WillCapturePhoto"
               object:nil];
  [center addObserver:self
             selector:@selector(hideCameraOverlay)
                 name:@"_UIImagePickerControllerUserDidCaptureItem"
               object:nil];
  [center addObserver:self
             selector:@selector(showCameraOverlay)
                 name:@"_UIImagePickerControllerUserDidRejectItem"
               object:nil];
  [center addObserver:self
             selector:@selector(temporarilyHideCameraOverlay)
                 name:@"UIApplicationSuspendedNotification"
               object:nil];
  // Restore overlay visibility when the app returns from the lock screen or
  // background — without this, a lock during capture mode leaves the overlay
  // hidden after unlock until the user takes+rejects a photo.
  [center addObserver:self
             selector:@selector(restoreCameraOverlayVisibility)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];
  [center addObserver:self
             selector:@selector(restoreCameraOverlayVisibility)
                 name:UIApplicationWillEnterForegroundNotification
               object:nil];

  // Diagnostics-only observers for the ~1% "camera goes black" reports. Handlers
  // do nothing but [NSLog] — no state mutation, no UI access, safe on any thread.
  // Torn down by the existing [removeObserver:self] in [viewWillDisappear] / [dealloc].
  [center addObserver:self
             selector:@selector(logCaptureSessionInterrupted:)
                 name:AVCaptureSessionWasInterruptedNotification
               object:nil];
  [center addObserver:self
             selector:@selector(logCaptureSessionInterruptionEnded:)
                 name:AVCaptureSessionInterruptionEndedNotification
               object:nil];
}

// AVFoundation may deliver these on a background thread. [NSLog] is
// thread-safe; do NOT touch UI or instance state from here.
- (void)logCaptureSessionInterrupted:(NSNotification *)note {
  id reason = note.userInfo[AVCaptureSessionInterruptionReasonKey];
  NSLog(@"[image_picker_ios] AVCaptureSession interrupted: reason=%@", reason);
}

- (void)logCaptureSessionInterruptionEnded:(NSNotification *)note {
  NSLog(@"[image_picker_ios] AVCaptureSession interruption ended");
}

// Remove notification observer if UI is being closed.
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  // Camera preview has two navigation routes.
  if (![[self.navigationController viewControllers] containsObject:self]) {
    // The view has been removed from the navigation stack or hierarchy.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Cancel any pending [performSelector:afterDelay:] dispatches — otherwise
    // [showCameraOverlay] / [hideCameraOverlay] could fire on a controller that
    // is mid-teardown.
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _hasRegisteredObserver = NO;
    [[UIApplication sharedApplication] setStatusBarHidden:NO];
  }
}

// Belt-and-suspenders cleanup: selector-based [NSNotificationCenter] observers
// are unsafe_unretained, so a stale observer on a deallocated instance crashes
// the process. [viewWillDisappear] normally clears this, but [dealloc] covers
// any teardown path that skips it.
- (void)dealloc {
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Slight delay on shutter-press smooths the transition from capture to preview.
- (void)handleWillCapturePhoto {
  [self performSelector:@selector(hideCameraOverlay) withObject:nil afterDelay:0.1];
}

@end
