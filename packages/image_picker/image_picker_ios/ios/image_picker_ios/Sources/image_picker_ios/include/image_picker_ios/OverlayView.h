//
//  OverlayView.h
//
//  Created by Roman Cinis on 20.11.2025
//  Copyright 2025 Roman Cinis. All rights reserved.
//

// Basic import to access custom [UIView], [CGRect] classes to use in [OverlayView] class.
#import <UIKit/UIKit.h>

// Basic description of the class interface, it's initializer and field.
@interface OverlayView : UIView  // Inherited from [UIView] class.

// UIView's are initialized with initWithFrame:(CGRect)frame initializer,
// [OverlayView] will also require optional path to overlay image (string)
// and optional opacity (integer).
- (id)initWithFrame:(CGRect)frame andPath:(NSString *)path andOpacity:(NSNumber *)opacity;

// Offset to be used for camera view translate, will be assigned during class initialization.
@property(assign, nonatomic) CGFloat offset;
@end
