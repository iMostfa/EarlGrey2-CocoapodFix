//
// Copyright 2017 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "GREYCAAnimationDelegate.h"

#include <objc/message.h>
#include <objc/runtime.h>

#import "CAAnimation+GREYApp.h"
#import "GREYFatalAsserts.h"
#import "GREYObjcRuntime.h"
#import "GREYSwizzler.h"

/**
 * Intercepts the CAAnimationDelegate::animationDidStart: call and directs it to the correct
 * implementation depending on the swizzled context.
 *
 * @param animation                   The animation the current class is the delegate off.
 * @param isInvokedFromSwizzledMethod @c YES if called from a swizzled method, @c NO otherwise.
 */
static void AnimationDidStart(id self, SEL _cmd, CAAnimation *animation,
                              BOOL isInvokedFromSwizzledMethod);

/**
 * Intercepts the CAAnimationDelegate::animationDidStop:finished: call and directs it to the
 * correct implementation depending on the swizzled context.
 *
 * @param animation                   The animation the current class is the delegate off.
 * @param finished                    @c YES if the animation has finished, @c NO if it stopped
 *                                    for other reasons.
 * @param isInvokedFromSwizzledMethod @c YES if called from a swizzled method, @c NO otherwise.
 */
static void AnimationDidStop(id self, SEL _cmd, CAAnimation *animation, BOOL finished,
                             BOOL isInvokedFromSwizzledMethod);

/**
 * Adds the @c originalSelector to the delegate's class if it does not respond to it.
 * If present, adds the @c swizzledSelector to the @c delegates's class and swizzles the
 * @originalSelector with the @c swizzledSelector for better tracking with EarlGrey
 * synchronization.
 *
 * @param delegate               The CAAnimationDelegate being swizzled.
 * @param originalSelector       The original selector method from CAAnimationDelegate to be
 *                               swizzled.
 * @param swizzledSelector       The custom EarlGrey selector for the @c originalSelector.
 * @param selfImplementation     The implementation of the @c originalSelector in the
 *                               GREYCAAnimationDelegate.
 * @param delegateImplementation The implementation for the @c originalSelector in the delegate
 *                               passed in.
 *
 * @return An id<CAAnimationDelegate> that has been appropriately instrumented for EarlGrey's
 *         synchronization.
 */
static id InstrumentSurrogateDelegate(id self, id delegate, SEL originalSelector,
                                      SEL swizzledSelector, IMP selfImplementation,
                                      IMP delegateImplementation);

/**
 * Animation did start selector for the animation delegate.
 */
static SEL gAnimationDidStartSelector;
/**
 * Swizzled animation did start selector for the animation delegate.
 */
static SEL gSwizzledAnimationDidStartSelector;
/**
 * Animation did stop selector for the animation delegate.
 */
static SEL gAnimationDidStopSelector;
/**
 * Swizzled animation did stop selector for the animation delegate.
 */
static SEL gSwizzledAnimationDidStopSelector;

@implementation GREYCAAnimationDelegate

+ (void)initialize {
  if (self == [GREYCAAnimationDelegate self]) {
    gAnimationDidStartSelector = @selector(animationDidStart:);
    gSwizzledAnimationDidStartSelector = @selector(greyswizzled_animationDidStart:);
    gAnimationDidStopSelector = @selector(animationDidStop:finished:);
    gSwizzledAnimationDidStopSelector = @selector(greyswizzled_animationDidStop:finished:);
  }
}

+ (id)surrogateDelegateForDelegate:(id)delegate {
  id outDelegate;
  if (!delegate) {
    // If the delegate is nil then create and return a new delegate.
    outDelegate = [[self alloc] initInternal];
  } else {
    IMP animationDidStartInstance = [self instanceMethodForSelector:gAnimationDidStartSelector];
    IMP delegateAnimationDidStartInstance = [delegate methodForSelector:gAnimationDidStartSelector];
    IMP animationDidStopInstance = [self instanceMethodForSelector:gAnimationDidStopSelector];
    IMP delegateAnimationDidStopInstance = [delegate methodForSelector:gAnimationDidStopSelector];
    outDelegate = InstrumentSurrogateDelegate(
        self, delegate, gAnimationDidStartSelector, gSwizzledAnimationDidStartSelector,
        animationDidStartInstance, delegateAnimationDidStartInstance);
    outDelegate = InstrumentSurrogateDelegate(
        self, outDelegate, gAnimationDidStopSelector, gSwizzledAnimationDidStopSelector,
        animationDidStopInstance, delegateAnimationDidStopInstance);
  }
  return outDelegate;
}

/** Internal initializer because init is marked as unavailable in the header. */
- (instancetype)initInternal {
  self = [super init];
  return self;
}

#pragma mark - CAAnimationDelegate

- (void)animationDidStart:(CAAnimation *)animation {
  AnimationDidStart(self, _cmd, animation, NO);
}

- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
  AnimationDidStop(self, _cmd, animation, finished, NO);
}

#pragma mark - Private

/**
 * Swizzled implementation of the CAAnimationDelegate::animationDidStart method.
 *
 * @param animation The animation the current class is the delegate off.
 */
- (void)greyswizzled_animationDidStart:(CAAnimation *)animation {
  AnimationDidStart(self, _cmd, animation, YES);
}

/**
 * Swizzled implementation of the CAAnimationDelegate::animationDidStop:finished: method.
 *
 * @param animation The animation the current class is the delegate off.
 * @param finished  @c YES if the animation has finished, @c NO if it stopped for other reasons.s
 */
- (void)greyswizzled_animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
  AnimationDidStop(self, _cmd, animation, finished, YES);
}

@end

static id InstrumentSurrogateDelegate(id self, id delegate, SEL originalSelector,
                                      SEL swizzledSelector, IMP selfImplementation,
                                      IMP delegateImplementation) {
  if (![delegate respondsToSelector:swizzledSelector]) {
    Class klass = [delegate class];
    // If the delegate's class does not implement the swizzled greyswizzled_animationDidStart:
    // method, then EarlGrey needs to swizzle it.
    if (![delegate respondsToSelector:originalSelector]) {
      // If animationDidStart: is not implemented by the delegate's class then we have to first
      // add it to the delegate class.
      [GREYObjcRuntime addInstanceMethodToClass:klass withSelector:originalSelector fromClass:self];

      // In case a delegate is passed in that has already been swizzled by EarlGrey, it needs to be
      // ensured that it is not re-swizzled. As a result, it is checked for the implementations of
      // the methods to be swizzled and if they are the same as those provided by EarlGrey on
      // swizzling.
    } else if (selfImplementation != delegateImplementation) {
      // Add the EarlGrey-implemented method to the delegate's class and swizzle it.
      [GREYObjcRuntime addInstanceMethodToClass:klass withSelector:swizzledSelector fromClass:self];
      BOOL swizzleSuccess = [[[GREYSwizzler alloc] init] swizzleClass:klass
                                                replaceInstanceMethod:originalSelector
                                                           withMethod:swizzledSelector];
      GREYFatalAssertWithMessage(swizzleSuccess, @"Cannot swizzle %@",
                                 NSStringFromSelector(swizzledSelector));
    }
  }
  return delegate;
}

static void AnimationDidStart(id self, SEL _cmd, CAAnimation *animation,
                              BOOL isInvokedFromSwizzledMethod) {
  [animation grey_setAnimationState:kGREYAnimationStarted];
  if (isInvokedFromSwizzledMethod) {
    INVOKE_ORIGINAL_IMP1(void, @selector(greyswizzled_animationDidStart:), animation);
  }
}

static void AnimationDidStop(id self, SEL _cmd, CAAnimation *animation, BOOL finished,
                             BOOL isInvokedFromSwizzledMethod) {
  // Starting with iOS11, calling [UIViewPropertyAnimator stopAnimation:] calls into
  // [UIViewPropertyAnimator finalizeStoppedAnimationWithPosition:] with a block that will in turn
  // call the CAAnimation delegate's animationDidStop:finished: method with animation parameter
  // set to NSNull. This check is added in order to stop the unrecognized selector call.
  if ([animation isEqual:[NSNull null]]) {
    return;
  }
  [animation grey_setAnimationState:kGREYAnimationStopped];
  if (isInvokedFromSwizzledMethod) {
    INVOKE_ORIGINAL_IMP2(void, @selector(greyswizzled_animationDidStop:finished:), animation,
                         finished);
  }
}
