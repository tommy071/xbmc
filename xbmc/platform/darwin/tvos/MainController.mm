/*
 *      Copyright (C) 2010-2013 Team XBMC
 *      http://xbmc.org
 *
 *  This Program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2, or (at your option)
 *  any later version.
 *
 *  This Program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with XBMC; see the file COPYING.  If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 *
 *  Refactored. Copyright (C) 2015 Team MrMC
 *  https://github.com/MrMC
 *
 */

#import "system.h"

#define BOOL XBMC_BOOL
#import "Application.h"

#import "cores/AudioEngine/AEFactory.h"
#import "guilib/GUIWindowManager.h"
#import "input/Key.h"
#import "input/ButtonTranslator.h"
#import "input/InputManager.h"
#import "interfaces/AnnouncementManager.h"
#import "network/NetworkServices.h"
#import "messaging/ApplicationMessenger.h"
#import "platform/darwin/AutoPool.h"
#import "platform/darwin/NSLogDebugHelpers.h"
#import "platform/darwin/tvos/MainEAGLView.h"
#import "platform/darwin/tvos/MainController.h"
#import "platform/darwin/tvos/MainApplication.h"
#import "platform/darwin/tvos/TVOSTopShelf.h"
#import "platform/darwin/ios-common/AnnounceReceiver.h"
#include "platform/xbmc.h"
#include "platform/XbmcContext.h"
#include "settings/AdvancedSettings.h"
#include "log.h"
#import "windowing/WindowingFactory.h"

#import <MediaPlayer/MPMediaItem.h>
#import <MediaPlayer/MPNowPlayingInfoCenter.h>

using namespace KODI::MESSAGING;

MainController *g_xbmcController;

//--------------------------------------------------------------
#pragma mark - MainController interface
@interface MainController ()
@property (strong, nonatomic) NSTimer *pressAutoRepeatTimer;
@property (strong, nonatomic) NSTimer *remoteIdleTimer;
@end

#pragma mark - MainController implementation
@implementation MainController

@synthesize m_lastGesturePoint;
@synthesize m_screenScale;
@synthesize m_screenIdx;
@synthesize m_screensize;
@synthesize m_nowPlayingInfo;
@synthesize m_directionOverride;
@synthesize m_direction;
@synthesize m_currentKey;
@synthesize m_clickResetPan;
@synthesize m_mimicAppleSiri;
@synthesize m_remoteIdleState;
@synthesize m_remoteIdleTimeout;
@synthesize m_shouldRemoteIdle;
@synthesize m_RemoteOSDSwipes;
@synthesize m_touchDirection;
@synthesize m_touchBeginSignaled;

#define NEW_REMOTE_HANDLING 0

#pragma mark - internal key press methods
- (void)sendButtonPressed:(int)buttonId
{
  int actionID;
  std::string actionName;
  
  // Translate using custom controller translator.
  if (CButtonTranslator::GetInstance().TranslateCustomControllerString(g_windowManager.GetActiveWindowID(), "SiriRemote", buttonId, actionID, actionName))
  {
    // break screensaver
    g_application.ResetSystemIdleTimer();
    g_application.ResetScreenSaver();
    
    // in case we wokeup the screensaver or screen - eat that action...
    if (g_application.WakeUpScreenSaverAndDPMS())
      return;
    CInputManager::GetInstance().QueueAction(CAction(actionID, 1.0f, 0.0f, actionName), true);
  }
  else
  {
    CLog::Log(LOGDEBUG, "ERROR mapping customcontroller action. CustomController: %s %i", "SiriRemote", buttonId);
  }
}
//--------------------------------------------------------------
//--------------------------------------------------------------
- (void)sendKeyDownUp:(XBMCKey)key
{
  XBMC_Event newEvent = {0};
  newEvent.key.keysym.sym = key;

  newEvent.type = XBMC_KEYDOWN;
  CWinEvents::MessagePush(&newEvent);

  newEvent.type = XBMC_KEYUP;
  CWinEvents::MessagePush(&newEvent);
}
- (void)sendKeyDown:(XBMCKey)key
{
  XBMC_Event newEvent = {0};
  newEvent.type = XBMC_KEYDOWN;
  newEvent.key.keysym.sym = key;
  CWinEvents::MessagePush(&newEvent);
}

#pragma mark - remote idle timer
//--------------------------------------------------------------

- (void)startRemoteTimer
{
  m_remoteIdleState = false;

  //PRINT_SIGNATURE();
  if (self.remoteIdleTimer != nil)
    [self stopRemoteTimer];
  if (m_shouldRemoteIdle)
  {
    NSDate *fireDate = [NSDate dateWithTimeIntervalSinceNow:m_remoteIdleTimeout];
    NSTimer *timer = [[NSTimer alloc] initWithFireDate:fireDate
                                      interval:0.0
                                      target:self
                                      selector:@selector(setRemoteIdleState)
                                      userInfo:nil
                                      repeats:NO];
    
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    self.remoteIdleTimer = timer;
  }
}

- (void)stopRemoteTimer
{
  //PRINT_SIGNATURE();
  if (self.remoteIdleTimer != nil)
  {
    [self.remoteIdleTimer invalidate];
    [self.remoteIdleTimer release];
    self.remoteIdleTimer = nil;
  }
  m_remoteIdleState = false;
}

- (void)setRemoteIdleState
{
  //PRINT_SIGNATURE();
  m_remoteIdleState = true;
}

#pragma mark - key press auto-repeat methods
//--------------------------------------------------------------
//--------------------------------------------------------------
// start repeating after 0.25s
#define REPEATED_KEYPRESS_DELAY_S 0.50
// pause 0.05s (50ms) between keypresses
#define REPEATED_KEYPRESS_PAUSE_S 0.05
//--------------------------------------------------------------

//- (void)startKeyPressTimer:(XBMCKey)keyId
- (void)startKeyPressTimer:(int)keyId
{
  [self startKeyPressTimer:keyId clickTime:REPEATED_KEYPRESS_PAUSE_S];
}

//- (void)startKeyPressTimer:(XBMCKey)keyId clickTime:(NSTimeInterval)interval
- (void)startKeyPressTimer:(int)keyId clickTime:(NSTimeInterval)interval
{
  //PRINT_SIGNATURE();
  if (self.pressAutoRepeatTimer != nil)
    [self stopKeyPressTimer];

  //[self sendKeyDown:keyId];
  [self sendButtonPressed:keyId];

  NSNumber *number = [NSNumber numberWithInt:keyId];
  NSDate *fireDate = [NSDate dateWithTimeIntervalSinceNow:REPEATED_KEYPRESS_DELAY_S];

  // schedule repeated timer which starts after REPEATED_KEYPRESS_DELAY_S
  // and fires every REPEATED_KEYPRESS_PAUSE_S
  NSTimer *timer = [[NSTimer alloc] initWithFireDate:fireDate
    interval:interval
    target:self
    selector:@selector(keyPressTimerCallback:)
    userInfo:number
    repeats:YES];

  // schedule the timer to the runloop
  [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
  self.pressAutoRepeatTimer = timer;
}
- (void)stopKeyPressTimer
{
  //PRINT_SIGNATURE();
  if (self.pressAutoRepeatTimer != nil)
  {
    [self.pressAutoRepeatTimer invalidate];
    [self.pressAutoRepeatTimer release];
    self.pressAutoRepeatTimer = nil;
  }
}
- (void)keyPressTimerCallback:(NSTimer*)theTimer
{
  //PRINT_SIGNATURE();
  // if queue is empty - skip this timer event before letting it process
  if (CWinEvents::GetQueueSize())
    return;

  NSNumber *keyId = [theTimer userInfo];
  //[self sendKeyDown:(XBMCKey)[keyId intValue]];
  [self sendButtonPressed:[keyId intValue]];
}

#pragma mark - remote helpers

//--------------------------------------------------------------
- (XBMCKey)getPanDirectionKey:(CGPoint)translation
{
  XBMCKey key = XBMCK_UNKNOWN;
  switch([self getPanDirection:translation])
  {
    case UIPanGestureRecognizerDirectionDown:
      key = XBMCK_DOWN;
      break;
    case UIPanGestureRecognizerDirectionUp:
      key = XBMCK_UP;
      break;
    case UIPanGestureRecognizerDirectionLeft:
      key = XBMCK_LEFT;
      break;
    case UIPanGestureRecognizerDirectionRight:
      key = XBMCK_RIGHT;
      break;
    case UIPanGestureRecognizerDirectionUndefined:
      break;
  }

  return key;
}

//--------------------------------------------------------------
- (UIPanGestureRecognizerDirection)getPanDirection:(CGPoint)translation
{
  int x = (int)translation.x;
  int y = (int)translation.y;
  int absX = x;
  int absY = y;
  
  if (absX < 0)
    absX *= -1;
  
  if (absY < 0)
    absY *= -1;
  
  bool horizontal, veritical;
  horizontal = ( absX > absY ) ;
  veritical = !horizontal;
  
  // Determine up, down, right, or left:
  bool swipe_up, swipe_down, swipe_left, swipe_right;
  swipe_left = (horizontal && x < 0);
  swipe_right = (horizontal && x >= 0);
  swipe_up = (veritical && y < 0);
  swipe_down = (veritical && y >= 0);
  
  if (swipe_down)
    return UIPanGestureRecognizerDirectionDown;
  if (swipe_up)
    return UIPanGestureRecognizerDirectionUp;
  if (swipe_left)
    return UIPanGestureRecognizerDirectionLeft;
  if (swipe_right)
    return UIPanGestureRecognizerDirectionRight;
  
  return UIPanGestureRecognizerDirectionUndefined;
  
}

//--------------------------------------------------------------
-(BOOL) shouldFastScroll
{
  // we dont want fast scroll in below windows, no point in going 15 places in home screen
  int window = g_windowManager.GetActiveWindow();
  
  if (window == WINDOW_HOME ||
      window == WINDOW_FULLSCREEN_LIVETV ||
      window == WINDOW_FULLSCREEN_VIDEO ||
      window == WINDOW_FULLSCREEN_RADIO ||
      (window >= WINDOW_SETTINGS_START && window <= WINDOW_SETTINGS_SERVICE)
      )
    return NO;
  
  return YES;
}

//--------------------------------------------------------------
-(BOOL) shouldOSDScroll
{
  // we might not want to scroll in below windows, fullscreen video playback is one
  int window = g_windowManager.GetActiveWindow();
  
  if (m_RemoteOSDSwipes &&
      (window == WINDOW_FULLSCREEN_LIVETV ||
      window == WINDOW_FULLSCREEN_VIDEO ||
      window == WINDOW_FULLSCREEN_RADIO
      ))
    return NO;
  
  return YES;
}

//--------------------------------------------------------------
- (void)setSiriRemote:(BOOL)enable
{
  m_mimicAppleSiri = enable;
}

//--------------------------------------------------------------
- (void)setRemoteIdleTimeout:(int)timeout
{
  m_remoteIdleTimeout = (float)timeout;
  [self startRemoteTimer];
}

- (void)setShouldRemoteIdle:(BOOL)idle
{
  //PRINT_SIGNATURE();
  m_shouldRemoteIdle = idle;
  [self startRemoteTimer];
}

- (void)setSiriRemoteOSDSwipes:(BOOL)enable
{
  //PRINT_SIGNATURE();
  m_RemoteOSDSwipes = enable;
}


//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - gesture methods
//--------------------------------------------------------------
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
  //PRINT_SIGNATURE();
  return YES;
}

//--------------------------------------------------------------
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{  
  if ([gestureRecognizer isKindOfClass:[UISwipeGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
    return YES;
  }
  if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
    return YES;
  }
  if ([gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
    return YES;
  }
  return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
#if (NEW_REMOTE_HANDLING)
  if (!m_mimicAppleSiri && [gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] && ([otherGestureRecognizer isKindOfClass:[UISwipeGestureRecognizer class]] || [otherGestureRecognizer isKindOfClass:[UITapGestureRecognizer class]]))
  {
    return YES;
  }
#endif
  return NO;
}

//--------------------------------------------------------------
// called before pressesBegan:withEvent: is called on the gesture recognizer
// for a new press. return NO to prevent the gesture recognizer from seeing this press
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceivePress:(UIPress *)press
{
  //PRINT_SIGNATURE();
  BOOL handled = YES;
  switch (press.type)
  {
    // single press key, but also detect hold and back to tvos.
    case UIPressTypeMenu:
      // menu is special.
      //  a) if at our home view, should return to atv home screen.
      //  b) if not, let it pass to us.
      if (g_windowManager.GetFocusedWindow() == WINDOW_HOME && !g_application.m_pPlayer->IsPlaying())
        handled = NO;
      break;

    // single press keys
    case UIPressTypeSelect:
    case UIPressTypePlayPause:
      break;

    // auto-repeat keys
    case UIPressTypeUpArrow:
    case UIPressTypeDownArrow:
    case UIPressTypeLeftArrow:
    case UIPressTypeRightArrow:
      break;

    default:
      handled = NO;
  }

  return handled;
}

//--------------------------------------------------------------
- (void)createSwipeGestureRecognizers
{
  UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(handleSwipe:)];

  swipeLeft.delaysTouchesBegan = NO;
  swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
  swipeLeft.delegate = self;
  [m_glView addGestureRecognizer:swipeLeft];
  [swipeLeft release];

  //single finger swipe right
  UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(handleSwipe:)];

  swipeRight.delaysTouchesBegan = NO;
  swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
  swipeRight.delegate = self;
  [m_glView addGestureRecognizer:swipeRight];
  [swipeRight release];

  //single finger swipe up
  UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(handleSwipe:)];

  swipeUp.delaysTouchesBegan = NO;
  swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
  swipeUp.delegate = self;
  [m_glView addGestureRecognizer:swipeUp];
  [swipeUp release];

  //single finger swipe down
  UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(handleSwipe:)];

  swipeDown.delaysTouchesBegan = NO;
  swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
  swipeDown.delegate = self;
  [m_glView addGestureRecognizer:swipeDown];
  [swipeDown release];
}
  
//--------------------------------------------------------------
- (void)createPanGestureRecognizers
{
  //PRINT_SIGNATURE();
  // for pan gestures with one finger
  auto pan = [[UIPanGestureRecognizer alloc]
    initWithTarget:self action:@selector(handlePan:)];
  pan.delegate = self;
  [m_glView addGestureRecognizer:pan];
  [pan release];
  m_clickResetPan = false;
}
//--------------------------------------------------------------
- (void)createTapGesturecognizers
{
  //PRINT_SIGNATURE();
  // tap side of siri remote pad
  auto upRecognizer = [[UITapGestureRecognizer alloc]
                       initWithTarget: self action: @selector(tapUpArrowPressed:)];
  upRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeUpArrow]];
  upRecognizer.delegate = self;
  [m_glView addGestureRecognizer: upRecognizer];
  [upRecognizer release];
  
  auto downRecognizer = [[UITapGestureRecognizer alloc]
                         initWithTarget: self action: @selector(tapDownArrowPressed:)];
  downRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeDownArrow]];
  downRecognizer.delegate = self;
  [m_glView addGestureRecognizer: downRecognizer];
  [downRecognizer release];
  
  auto leftRecognizer = [[UITapGestureRecognizer alloc]
                         initWithTarget: self action: @selector(tapLeftArrowPressed:)];
  leftRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeLeftArrow]];
  leftRecognizer.delegate = self;
  [m_glView addGestureRecognizer: leftRecognizer];
  [leftRecognizer release];
  
  auto rightRecognizer = [[UITapGestureRecognizer alloc]
                          initWithTarget: self action: @selector(tapRightArrowPressed:)];
  rightRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeRightArrow]];
  rightRecognizer.delegate = self;
  [m_glView addGestureRecognizer: rightRecognizer];
  [rightRecognizer release];
}
//--------------------------------------------------------------
- (void)createPressGesturecognizers
{
  //PRINT_SIGNATURE();
  // we need UILongPressGestureRecognizer here because it will give
  // UIGestureRecognizerStateBegan AND UIGestureRecognizerStateEnded
  // even if we hold down for a long time. UITapGestureRecognizer
  // will eat the ending on long holds and we never see it.
  auto upRecognizer = [[UILongPressGestureRecognizer alloc]
    initWithTarget: self action: @selector(IRRemoteUpArrowPressed:)];
  upRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeUpArrow]];
  upRecognizer.minimumPressDuration = 0.01;
  upRecognizer.delegate = self;
  [self.view addGestureRecognizer: upRecognizer];
  [upRecognizer release];

  auto downRecognizer = [[UILongPressGestureRecognizer alloc]
    initWithTarget: self action: @selector(IRRemoteDownArrowPressed:)];
  downRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeDownArrow]];
  downRecognizer.minimumPressDuration = 0.01;
  downRecognizer.delegate = self;
  [self.view addGestureRecognizer: downRecognizer];
  [downRecognizer release];

  auto leftRecognizer = [[UILongPressGestureRecognizer alloc]
    initWithTarget: self action: @selector(IRRemoteLeftArrowPressed:)];
  leftRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeLeftArrow]];
  leftRecognizer.minimumPressDuration = 0.01;
  leftRecognizer.delegate = self;
  [self.view addGestureRecognizer: leftRecognizer];
  [leftRecognizer release];

  auto rightRecognizer = [[UILongPressGestureRecognizer alloc]
    initWithTarget: self action: @selector(IRRemoteRightArrowPressed:)];
  rightRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeRightArrow]];
  rightRecognizer.minimumPressDuration = 0.01;
  rightRecognizer.delegate = self;
  [self.view addGestureRecognizer: rightRecognizer];
  [rightRecognizer release];
  
  // we always have these under tvos
  auto menuRecognizer = [[UITapGestureRecognizer alloc]
                         initWithTarget: self action: @selector(menuPressed:)];
  menuRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeMenu]];
  menuRecognizer.delegate  = self;
  [m_glView addGestureRecognizer: menuRecognizer];
  [menuRecognizer release];
  
  auto playPauseRecognizer = [[UITapGestureRecognizer alloc]
                              initWithTarget: self action: @selector(playPausePressed:)];
  playPauseRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypePlayPause]];
  playPauseRecognizer.delegate  = self;
  [m_glView addGestureRecognizer: playPauseRecognizer];
  [playPauseRecognizer release];
  
  auto selectRecognizer = [[UILongPressGestureRecognizer alloc]
                          initWithTarget: self action: @selector(selectPressed:)];
  selectRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeSelect]];
  selectRecognizer.minimumPressDuration = 0.01;
  selectRecognizer.delegate = self;
  [self.view addGestureRecognizer: selectRecognizer];
  [selectRecognizer release];
  
}

//--------------------------------------------------------------
- (void)buttonHoldSelect
{
  self.m_holdCounter++;
  [self.m_holdTimer invalidate];
  //[self sendKeyDownUp:XBMCK_c];
  [self sendButtonPressed:7];
}
//--------------------------------------------------------------
- (void) activateKeyboard:(UIView *)view
{
  //PRINT_SIGNATURE();
  [self.view addSubview:view];
  m_glView.userInteractionEnabled = NO;
}
//--------------------------------------------------------------
- (void) deactivateKeyboard:(UIView *)view
{
  //PRINT_SIGNATURE();
  [view removeFromSuperview];
  m_glView.userInteractionEnabled = YES; 
  [self becomeFirstResponder];
}
//--------------------------------------------------------------
- (void)menuPressed:(UITapGestureRecognizer *)sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [self sendButtonPressed:6];
      
      // start remote timeout
      [self startRemoteTimer];
      break;
    default:
      break;
  }
}
//--------------------------------------------------------------
- (void)selectPressed:(UITapGestureRecognizer *)sender
{
  // if we have clicked select while scrolling up/down we need to reset direction of pan
  m_clickResetPan = true;
  
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      self.m_holdCounter = 0;
      self.m_holdTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(buttonHoldSelect) userInfo:nil repeats:YES];
      break;
    case UIGestureRecognizerStateChanged:
      if (self.m_holdCounter > 1)
      {
        [self.m_holdTimer invalidate];
        //[self sendKeyDownUp:XBMCK_c];
        [self sendButtonPressed:7];
      }
      break;
    case UIGestureRecognizerStateEnded:
      [self.m_holdTimer invalidate];
      if (self.m_holdCounter < 1)
      {
        //[self sendKeyDownUp:XBMCK_RETURN];
        [self sendButtonPressed:5];
      }
      
      // start remote timeout
      [self startRemoteTimer];
      break;
    default:
      break;
  }
}

- (void)playPausePressed:(UITapGestureRecognizer *) sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      //[self sendKeyDownUp:XBMCK_MEDIA_PLAY_PAUSE];
      [self sendButtonPressed:12];
      // start remote timeout
      [self startRemoteTimer];
      break;
    default:
      break;
  }
}

//--------------------------------------------------------------
- (IBAction)IRRemoteUpArrowPressed:(UIGestureRecognizer *)sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      //[self startKeyPressTimer:XBMCK_UP];
      [self startKeyPressTimer:1];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [self stopKeyPressTimer];
      //[self sendKeyUp:XBMCK_UP];
      
      // start remote timeout
      [self startRemoteTimer];
      break;
    default:
      break;
  }
}
//--------------------------------------------------------------
- (IBAction)IRRemoteDownArrowPressed:(UIGestureRecognizer *)sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      //[self startKeyPressTimer:XBMCK_DOWN];
      [self startKeyPressTimer:2];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [self stopKeyPressTimer];
      //[self sendKeyUp:XBMCK_DOWN];
      
      // start remote timeout
      [self startRemoteTimer];
      break;
    default:
      break;
  }
}
//--------------------------------------------------------------
- (IBAction)IRRemoteLeftArrowPressed:(UIGestureRecognizer *)sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      //[self startKeyPressTimer:XBMCK_LEFT];
      [self startKeyPressTimer:3];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [self stopKeyPressTimer];
      //[self sendKeyUp:XBMCK_LEFT];
      
      // start remote timeout
      [self startRemoteTimer];
      break;
    default:
      break;
  }
}
//--------------------------------------------------------------
- (IBAction)IRRemoteRightArrowPressed:(UIGestureRecognizer *)sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      //[self startKeyPressTimer:XBMCK_RIGHT];
      [self startKeyPressTimer:4];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [self stopKeyPressTimer];
      //[self sendKeyUp:XBMCK_RIGHT];
      
      // start remote timeout
      [self startRemoteTimer];
      break;
    default:
      break;
  }
}

//--------------------------------------------------------------
- (IBAction)tapUpArrowPressed:(UIGestureRecognizer *)sender
{
  if (!m_remoteIdleState)
  {
    [self sendButtonPressed:1];
    //[self sendKeyDownUp:XBMCK_UP];
  }
  [self startRemoteTimer];
}
//--------------------------------------------------------------
- (IBAction)tapDownArrowPressed:(UIGestureRecognizer *)sender
{
  if (!m_remoteIdleState)
  {
    //[self sendKeyDownUp:XBMCK_DOWN];
    [self sendButtonPressed:2];
  }
  [self startRemoteTimer];
}
//--------------------------------------------------------------
- (IBAction)tapLeftArrowPressed:(UIGestureRecognizer *)sender
{
  if (!m_remoteIdleState)
  {
    [self sendButtonPressed:3];
    //[self sendKeyDownUp:XBMCK_LEFT];
  }
  [self startRemoteTimer];
}
//--------------------------------------------------------------
- (IBAction)tapRightArrowPressed:(UIGestureRecognizer *)sender
{
  if (!m_remoteIdleState)
  {
    //[self sendKeyDownUp:XBMCK_RIGHT];
    [self sendButtonPressed:4];
  }
  [self startRemoteTimer];
}

//--------------------------------------------------------------
- (IBAction)handlePan:(UIPanGestureRecognizer *)sender 
{
  if (!m_remoteIdleState)
  {
    if (m_appAlive == YES) //NO GESTURES BEFORE WE ARE UP AND RUNNING
    {
      if (m_mimicAppleSiri)
      {
        if ([self shouldOSDScroll])
        {
          static UIPanGestureRecognizerDirection direction = UIPanGestureRecognizerDirectionUndefined;
          // speed       == how many clicks full swipe will give us(1000x1000px)
          // minVelocity == min velocity to trigger fast scroll, add this to settings?
          float speed = 240.0;
          float minVelocity = 1300.0;
          switch (sender.state) {
              
            case UIGestureRecognizerStateBegan: {
              
              if (direction == UIPanGestureRecognizerDirectionUndefined)
              {
                m_lastGesturePoint = [sender translationInView:sender.view];
                m_lastGesturePoint.x = m_lastGesturePoint.x/1.92;
                m_lastGesturePoint.y = m_lastGesturePoint.y/1.08;
                
                m_direction = [self getPanDirection:m_lastGesturePoint];
                m_directionOverride = false;
              }
              
              break;
            }
              
            case UIGestureRecognizerStateChanged:
            {
              CGPoint gesturePoint = [sender translationInView:sender.view];
              gesturePoint.x = gesturePoint.x/1.92;
              gesturePoint.y = gesturePoint.y/1.08;
              
              CGPoint gestureMovement;
              gestureMovement.x = gesturePoint.x - m_lastGesturePoint.x;
              gestureMovement.y = gesturePoint.y - m_lastGesturePoint.y;
              direction = [self getPanDirection:gestureMovement];
              
              CGPoint velocity = [sender velocityInView:sender.view];
              CGFloat velocityX = (0.2*velocity.x);
              CGFloat velocityY = (0.2*velocity.y);
              
              if (ABS(velocityY) > minVelocity || ABS(velocityX) > minVelocity || m_directionOverride)
              {
                direction = m_direction;
                // Override direction to correct swipe errors
                m_directionOverride = true;
              }
              
              switch (direction)
              {
                case UIPanGestureRecognizerDirectionUp:
                {
                  if ((ABS(m_lastGesturePoint.y - gesturePoint.y) > speed) || ABS(velocityY) > minVelocity )
                  {
                    //[self sendKeyDownUp:XBMCK_UP];
                    [self sendButtonPressed:8];
                    if (ABS(velocityY) > minVelocity && [self shouldFastScroll])
                    {
                      //[self sendKeyDownUp:XBMCK_UP];
                      [self sendButtonPressed:8];
                    }
                    m_lastGesturePoint = gesturePoint;
                  }
                  break;
                }
                case UIPanGestureRecognizerDirectionDown:
                {
                  if ((ABS(m_lastGesturePoint.y - gesturePoint.y) > speed) || ABS(velocityY) > minVelocity)
                  {
                    //[self sendKeyDownUp:XBMCK_DOWN];
                    [self sendButtonPressed:9];
                    if (ABS(velocityY) > minVelocity && [self shouldFastScroll])
                    {
                      //[self sendKeyDownUp:XBMCK_DOWN];
                      [self sendButtonPressed:9];
                    }
                    m_lastGesturePoint = gesturePoint;
                  }
                  break;
                }
                case UIPanGestureRecognizerDirectionLeft:
                {
                  // add 80 px to slow left/right swipes, it matched up down better
                  if ((ABS(m_lastGesturePoint.x - gesturePoint.x) > speed+80) || ABS(velocityX) > minVelocity)
                  {
                    //[self sendKeyDownUp:XBMCK_LEFT];
                    [self sendButtonPressed:10];
                    if (ABS(velocityX) > minVelocity && [self shouldFastScroll])
                    {
                      //[self sendKeyDownUp:XBMCK_LEFT];
                      [self sendButtonPressed:10];
                    }
                    m_lastGesturePoint = gesturePoint;
                  }
                  break;
                }
                case UIPanGestureRecognizerDirectionRight:
                {
                  // add 80 px to slow left/right swipes, it matched up down better
                  if ((ABS(m_lastGesturePoint.x - gesturePoint.x) > speed+80) || ABS(velocityX) > minVelocity)
                  {
                    //[self sendKeyDownUp:XBMCK_RIGHT];
                    [self sendButtonPressed:11];
                    if (ABS(velocityX) > minVelocity && [self shouldFastScroll])
                    {
                      //[self sendKeyDownUp:XBMCK_RIGHT];
                      [self sendButtonPressed:11];
                    }
                    m_lastGesturePoint = gesturePoint;
                  }
                  break;
                }
                default:
                {
                  break;
                }
              }
            }
              
            case UIGestureRecognizerStateEnded: {
              direction = UIPanGestureRecognizerDirectionUndefined;
              // start remote idle timer
              [self startRemoteTimer];
              break;
            }
              
            default:
              break;
          }
        }
      }
      else // dont mimic apple siri remote
      {
        XBMCKey key;
        switch (sender.state)
        {
          case UIGestureRecognizerStateBegan:
          {
            m_currentClick = -1;
            m_currentKey = XBMCK_UNKNOWN;
            m_touchBeginSignaled = false;
            break;
          }
          case UIGestureRecognizerStateChanged:
          {
#if (NEW_REMOTE_HANDLING)
            CGPoint gesturePoint = [sender translationInView:m_glView];
            gesturePoint.x = gesturePoint.x/1.92;
            gesturePoint.y = gesturePoint.y/1.08;
            
            key = [self getPanDirectionKey:gesturePoint];
            
            // ignore UP/DOWN swipes while in full screen playback
            if (g_windowManager.GetFocusedWindow() != WINDOW_FULLSCREEN_VIDEO ||
                key == XBMCK_LEFT ||
                key == XBMCK_RIGHT)
            {
              int click;
              int absX = gesturePoint.x;
              int absY = gesturePoint.y;
              
              if (absX < 0)
                absX *= -1;
              
              if (absY < 0)
                absY *= -1;
              
              if (key == XBMCK_RIGHT || key == XBMCK_LEFT)
              {
                if (absX > 200)
                  click = 2;
                else if (absX > 70)
                  click = 1;
                else
                  click = 0;
              }
              else
              {
                if (absY > 200)
                  click = 2;
                else if (absY > 100)
                  click = 1;
                else
                  click = 0;
              }
              
              if (m_clickResetPan || m_currentKey != key || click != m_currentClick)
              {
                [self stopKeyPressTimer];
                //[self sendKeyUp:m_currentKey];
                
                if (click != m_currentClick)
                {
                  m_currentClick = click;
                }
                if (m_currentKey == XBMCK_UNKNOWN || m_clickResetPan ||
                    ((m_currentKey == XBMCK_RIGHT && key == XBMCK_LEFT) ||
                     (m_currentKey == XBMCK_LEFT && key == XBMCK_RIGHT) ||
                     (m_currentKey == XBMCK_UP && key == XBMCK_DOWN) ||
                     (m_currentKey == XBMCK_DOWN && key == XBMCK_UP))
                    )
                {
                  m_clickResetPan = false;
                  m_currentKey = key;
                }
                
                if (m_currentClick == 2)
                {
                  //fast click
                  [self startKeyPressTimer:m_currentKey clickTime:0.20];
                  LOG("fast click");
                }
                else if (m_currentClick == 1)
                {
                  // slow click
                  [self startKeyPressTimer:m_currentKey clickTime:0.80];
                  LOG("slow click");
                }
              }
#else
              int keyId = 0;
              if (!m_touchBeginSignaled && m_touchDirection)
              {
                switch (m_touchDirection)
                {
                  case UISwipeGestureRecognizerDirectionRight:
                    keyId = 11;
                    break;
                  case UISwipeGestureRecognizerDirectionLeft:
                    keyId = 10;
                    break;
                  case UISwipeGestureRecognizerDirectionUp:
                    keyId = 8;
                    break;
                  case UISwipeGestureRecognizerDirectionDown:
                    keyId = 9;
                    break;
                  default:
                    break;
                }
                m_touchBeginSignaled = true;
                [self startKeyPressTimer:keyId];
#endif
            }
            break;
          }
          case UIGestureRecognizerStateEnded:
          case UIGestureRecognizerStateCancelled:
#if (NEW_REMOTE_HANDLING)
            [self stopKeyPressTimer];
#else
            if (m_touchBeginSignaled)
            {
              m_touchBeginSignaled = false;
              m_touchDirection = NULL;
              [self stopKeyPressTimer];
              //[self sendKeyUp:key];
            }
#endif
            // start remote idle timer
            [self startRemoteTimer];
            break;
          default:
            break;
        }
      }
    }
  }
}

//--------------------------------------------------------------
- (IBAction)handleSwipe:(UISwipeGestureRecognizer *)sender
{
  if (!m_remoteIdleState)
  {
    if(!m_mimicAppleSiri && m_appAlive == YES)//NO GESTURES BEFORE WE ARE UP AND RUNNING
    {
#if (NEW_REMOTE_HANDLING)
      switch ([sender direction])
      {
        case UISwipeGestureRecognizerDirectionRight:
          //[self sendKeyDownUp:XBMCK_RIGHT];
          [self sendButtonPressed:11];
          break;
        case UISwipeGestureRecognizerDirectionLeft:
          //[self sendKeyDownUp:XBMCK_LEFT];
          [self sendButtonPressed:10];
          break;
        case UISwipeGestureRecognizerDirectionUp:
          //[self sendKeyDownUp:XBMCK_UP];
          [self sendButtonPressed:8];
          break;
        case UISwipeGestureRecognizerDirectionDown:
          //[self sendKeyDownUp:XBMCK_DOWN];
          [self sendButtonPressed:9];
          break;
      }
#endif
    }
    m_touchDirection = [sender direction];
  }
  // start remote idle timer
  [self startRemoteTimer];
}

#pragma mark -
- (void) insertVideoView:(UIView*)view
{
  [self.view insertSubview:view belowSubview:m_glView];
  [self.view setNeedsDisplay];
}

- (void) removeVideoView:(UIView*)view
{
  [view removeFromSuperview];
}

- (id)initWithFrame:(CGRect)frame withScreen:(UIScreen *)screen
{ 
  m_screenIdx = 0;
  self = [super init];
  if (!self)
    return nil;

  m_pause = FALSE;
  m_appAlive = FALSE;
  m_animating = FALSE;

  m_isPlayingBeforeInactive = NO;
  m_bgTask = UIBackgroundTaskInvalid;

  m_window = [[UIWindow alloc] initWithFrame:frame];
  [m_window setRootViewController:self];  
  m_window.screen = screen;
  m_window.backgroundColor = [UIColor blackColor];
  // Turn off autoresizing
  m_window.autoresizingMask = 0;
  m_window.autoresizesSubviews = NO;

  [self enableScreenSaver];

  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver: self
     selector: @selector(observeDefaultCenterStuff:) name: nil object: nil];

  [m_window makeKeyAndVisible];
  g_xbmcController = self;

  return self;
}
//--------------------------------------------------------------
- (void)dealloc
{
  // stop background task (if running)
  [self disableBackGroundTask];

  [self stopAnimation];
  [m_glView release];
  [m_window release];
  
  NSNotificationCenter *center;
  // take us off the default center for our app
  center = [NSNotificationCenter defaultCenter];
  [center removeObserver: self];
  
  [super dealloc];
}
//--------------------------------------------------------------
- (void)loadView
{
  [super loadView];

  self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.view.autoresizesSubviews = YES;
  
  m_glView = [[MainEAGLView alloc] initWithFrame:self.view.bounds withScreen:[UIScreen mainScreen]];

  // Check if screen is Retina
  // m_screenScale = [[UIScreen mainScreen] nativeScale];
  m_screenScale = 1.0;
  [self.view addSubview: m_glView];
}
//--------------------------------------------------------------
- (void)viewDidLoad
{
  [super viewDidLoad];
  
  [self createSwipeGestureRecognizers];
  [self createPanGestureRecognizers];
  [self createPressGesturecognizers];
  [self createTapGesturecognizers];
}
//--------------------------------------------------------------
- (void)viewWillAppear:(BOOL)animated
{
  [self resumeAnimation];
  [super viewWillAppear:animated];
}
//--------------------------------------------------------------
- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  [self becomeFirstResponder];
  [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
}
//--------------------------------------------------------------
- (void)viewWillDisappear:(BOOL)animated
{  
  [self pauseAnimation];
  [super viewWillDisappear:animated];
}
//--------------------------------------------------------------
- (void)viewDidUnload
{
  [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
  [self resignFirstResponder];
  [super viewDidUnload];
}
//--------------------------------------------------------------
- (UIView *)inputView
{
  // override our input view to an empty view
  // this prevents the on screen keyboard
  // which would be shown whenever this UIResponder
  // becomes the first responder (which is always the case!)
  // caused by implementing the UIKeyInput protocol
  return [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
}
//--------------------------------------------------------------
- (BOOL)canBecomeFirstResponder
{
  return YES;
}
//--------------------------------------------------------------
- (void)setFramebuffer
{
  if (!m_pause)
    [m_glView setFramebuffer];
}
//--------------------------------------------------------------
- (bool)presentFramebuffer
{
  if (!m_pause)
    return [m_glView presentFramebuffer];
  else
    return FALSE;
}
//--------------------------------------------------------------
- (CGSize)getScreenSize
{
  m_screensize.width  = m_glView.bounds.size.width  * m_screenScale;
  m_screensize.height = m_glView.bounds.size.height * m_screenScale;
  return m_screensize;
}

//--------------------------------------------------------------
- (void)didReceiveMemoryWarning
{
  PRINT_SIGNATURE();
  // Releases the view if it doesn't have a superview.
  [super didReceiveMemoryWarning];
  // Release any cached data, images, etc. that aren't in use.
}
//--------------------------------------------------------------
- (void)enableBackGroundTask
{
  if (m_bgTask != UIBackgroundTaskInvalid)
  {
    [[UIApplication sharedApplication] endBackgroundTask: m_bgTask];
    m_bgTask = UIBackgroundTaskInvalid;
  }
  LOG(@"%s: beginBackgroundTask", __PRETTY_FUNCTION__);
  // we have to alloc the background task for keep network working after screen lock and dark.
  m_bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
}
//--------------------------------------------------------------
- (void)disableBackGroundTask
{
  if (m_bgTask != UIBackgroundTaskInvalid)
  {
    LOG(@"%s: endBackgroundTask", __PRETTY_FUNCTION__);
    [[UIApplication sharedApplication] endBackgroundTask: m_bgTask];
    m_bgTask = UIBackgroundTaskInvalid;
  }
}
//--------------------------------------------------------------
- (void)disableSystemSleep
{
}
//--------------------------------------------------------------
- (void)enableSystemSleep
{
}
//--------------------------------------------------------------
- (void)disableScreenSaver
{
  m_disableIdleTimer = YES;
  [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
}
//--------------------------------------------------------------
- (void)enableScreenSaver
{
  m_disableIdleTimer = NO;
  [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
}

//--------------------------------------------------------------
- (bool)resetSystemIdleTimer
{
  // this is silly :)
  // when system screen saver kicks off, we switch to UIApplicationStateInactive, the only way
  // to get out of the screensaver is to call ourself to open an custom URL that is registered
  // in our Info.plist. The openURL method of UIApplication must be supported but we can just
  // reply NO and we get restored to UIApplicationStateActive.
  bool inActive = [UIApplication sharedApplication].applicationState == UIApplicationStateInactive;
  if (inActive)
  {
    NSURL *url = [NSURL URLWithString:@"kodi://wakeup"];
    [[UIApplication sharedApplication] openURL:url];
  }

  return inActive;
}

//--------------------------------------------------------------
- (UIScreenMode*) preferredScreenMode:(UIScreen*) screen
{
  // tvOS only support one mode, the current one.
  return [screen currentMode];
}

//--------------------------------------------------------------
- (NSArray<UIScreenMode *> *) availableScreenModes:(UIScreen*) screen
{
  // tvOS only support one mode, the current one,
  // pass back an array with this inside.
  NSMutableArray *array = [[[NSMutableArray alloc] initWithCapacity:1] autorelease];
  [array addObject:[screen currentMode]];
  return array;
}

//--------------------------------------------------------------
- (bool)changeScreen:(unsigned int)screenIdx withMode:(UIScreenMode *)mode
{
  return true;
}
//--------------------------------------------------------------
- (void)enterBackground
{
  PRINT_SIGNATURE();
  // We have 5 seconds before the OS will force kill us for delaying too long.
  XbmcThreads::EndTime timer(4500);

  // this should not be required as we 'should' get becomeInactive before enterBackground
  if (g_application.m_pPlayer->IsPlaying() && !g_application.m_pPlayer->IsPaused())
  {
    m_isPlayingBeforeInactive = YES;
    CApplicationMessenger::GetInstance().SendMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  }

  g_Windowing.OnAppFocusChange(false);

  // Apple says to disable ZeroConfig when moving to background
  CNetworkServices::GetInstance().StopZeroconf();

  if (m_isPlayingBeforeInactive)
  {
    // if we were playing and have paused, then
    // enable a background task to keep the network alive
    [self enableBackGroundTask];
  }
  else
  {
    // if we are not playing/pause when going to background
    // close out network shares as we can get fully suspended.
    g_application.CloseNetworkShares();
  }

  // OnAppFocusChange triggers an AE suspend.
  // Wait for AE to suspend and delete the audio sink, this allows
  // AudioOutputUnitStop to complete and AVAudioSession to be set inactive.
  // Note that to user, we moved into background to user but we
  // are really waiting here for AE to suspend.
  while (!CAEFactory::IsSuspended() && !timer.IsTimePast())
    usleep(250*1000);
}

- (void)enterForegroundDelayed:(id)arg
{
  // MCRuntimeLib_Initialized is only true if
  // we were running and got moved to background
  while(!g_application.IsAppInitialized())
    usleep(50*1000);

  g_Windowing.OnAppFocusChange(true);

  // when we come back, restore playing if we were.
  if (m_isPlayingBeforeInactive)
  {
    CApplicationMessenger::GetInstance().SendMsg(TMSG_MEDIA_UNPAUSE);
    m_isPlayingBeforeInactive = NO;
  }
  // restart ZeroConfig (if stopped)
  CNetworkServices::GetInstance().StartZeroconf();

  // do not update if we are already updating
  if (!(g_application.IsVideoScanning() || g_application.IsMusicScanning()))
    g_application.UpdateLibraries();

  // this will fire only if we are already alive and have 'menu'ed out and back
  ANNOUNCEMENT::CAnnouncementManager::GetInstance().Announce(ANNOUNCEMENT::System, "xbmc", "OnWake");

  // this handles what to do if we got pushed
  // into foreground by a topshelf item select/play
  CTVOSTopShelf::GetInstance().RunTopShelf();
}

- (void)enterForeground
{
  PRINT_SIGNATURE();
  // stop background task (if running)
  [self disableBackGroundTask];

  [NSThread detachNewThreadSelector:@selector(enterForegroundDelayed:) toTarget:self withObject:nil];
}

- (void)becomeInactive
{
  // if we were interrupted, already paused here
  // else if user background us or lock screen, only pause video here, audio keep playing.
  if (g_application.m_pPlayer->IsPlayingVideo() &&
     !g_application.m_pPlayer->IsPaused())
  {
    m_isPlayingBeforeInactive = YES;
    CApplicationMessenger::GetInstance().SendMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  }
}

#pragma mark - runtime routines
//--------------------------------------------------------------
- (void)pauseAnimation
{
  //PRINT_SIGNATURE();
  m_pause = TRUE;
  g_application.SetRenderGUI(false);
}
//--------------------------------------------------------------
- (void)resumeAnimation
{
  //PRINT_SIGNATURE();
  m_pause = FALSE;
  g_application.SetRenderGUI(true);
}
//--------------------------------------------------------------
- (void)startAnimation
{
  //PRINT_SIGNATURE();
  if (m_animating == NO && [m_glView getContext])
  {
    // kick off an animation thread
    m_animationThreadLock = [[NSConditionLock alloc] initWithCondition: FALSE];
    m_animationThread = [[NSThread alloc] initWithTarget:self
      selector:@selector(runAnimation:) object:m_animationThreadLock];
    [m_animationThread start];
    m_animating = TRUE;
  }
}
//--------------------------------------------------------------
- (void)stopAnimation
{
  //PRINT_SIGNATURE();
  if (m_animating == NO && [m_glView getContext])
  {
    m_appAlive = FALSE;
    m_animating = FALSE;
    if (!g_application.m_bStop)
    {
      CApplicationMessenger::GetInstance().PostMsg(TMSG_QUIT);
    }

    CAnnounceReceiver::GetInstance()->DeInitialize();

    // wait for animation thread to die
    if ([m_animationThread isFinished] == NO)
      [m_animationThreadLock lockWhenCondition:TRUE];
  }
}

int KODI_Run(bool renderGUI)
{
  int status = -1;
  
  //this can't be set from CAdvancedSettings::Initialize()
  //because it will overwrite the loglevel set with the --debug flag
#ifdef _DEBUG
  g_advancedSettings.m_logLevel     = LOG_LEVEL_DEBUG;
  g_advancedSettings.m_logLevelHint = LOG_LEVEL_DEBUG;
#else
  g_advancedSettings.m_logLevel     = LOG_LEVEL_NORMAL;
  g_advancedSettings.m_logLevelHint = LOG_LEVEL_NORMAL;
#endif
  CLog::SetLogLevel(g_advancedSettings.m_logLevel);
  
  // not a failure if returns false, just means someone
  // did the init before us.
  if (!g_advancedSettings.Initialized())
    g_advancedSettings.Initialize();
  
  if (!g_application.Create())
  {
    ELOG(@"ERROR: Unable to create application. Exiting");
    return status;
  }
  
  CAnnounceReceiver::GetInstance()->Initialize();
  
  if (renderGUI && !g_application.CreateGUI())
  {
    ELOG(@"ERROR: Unable to create GUI. Exiting");
    return status;
  }
  if (!g_application.Initialize())
  {
    ELOG(@"ERROR: Unable to Initialize. Exiting");
    return status;
  }
  
  try
  {
    status = g_application.Run();
  }
  catch(...)
  {
    ELOG(@"ERROR: Exception caught on main loop. Exiting");
    status = -1;
  }

  return status;
}

//--------------------------------------------------------------
- (void)runAnimation:(id)arg
{
  CCocoaAutoPool outerpool;
  [[NSThread currentThread] setName:@"XBMC_Run"];
  
  // signal the thread is alive
  NSConditionLock* myLock = arg;
  [myLock lock];
  
  // Prevent child processes from becoming zombies on exit
  // if not waited upon. See also Util::Command
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_flags = SA_NOCLDWAIT;
  sa.sa_handler = SIG_IGN;
  sigaction(SIGCHLD, &sa, NULL);
  
  setlocale(LC_NUMERIC, "C");
  
  int status = 0;
  try
  {
    // set up some Kodi specific relationships
    XBMC::Context run_context;
    m_appAlive = TRUE;
    // start up with gui enabled
    status = KODI_Run(true);
    // we exited or died.
    g_application.SetRenderGUI(false);
  }
  catch(...)
  {
    m_appAlive = FALSE;
    ELOG(@"%sException caught on main loop status=%d. Exiting", __PRETTY_FUNCTION__, status);
  }
  
  // signal the thread is dead
  [myLock unlockWithCondition:TRUE];
  
  [self enableScreenSaver];
  [self enableSystemSleep];
  [self performSelectorOnMainThread:@selector(CallExit) withObject:nil  waitUntilDone:NO];
}

- (void) CallExit
{
  exit(0);
}

//--------------------------------------------------------------
- (void)remoteControlReceivedWithEvent:(UIEvent*)receivedEvent
{
  if (receivedEvent.type == UIEventTypeRemoteControl)
  {
    switch (receivedEvent.subtype)
    {
      case UIEventSubtypeRemoteControlTogglePlayPause:
        CApplicationMessenger::GetInstance().PostMsg(TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PLAYER_PLAYPAUSE)));
        break;
      case UIEventSubtypeRemoteControlPlay:
        [self sendButtonPressed:13];
        break;
      case UIEventSubtypeRemoteControlPause:
        [self sendButtonPressed:14];
        break;
      case UIEventSubtypeRemoteControlStop:
        [self sendButtonPressed:15];
        break;
      case UIEventSubtypeRemoteControlNextTrack:
        [self sendButtonPressed:16];
        break;
      case UIEventSubtypeRemoteControlPreviousTrack:
        [self sendButtonPressed:17];
        break;
      case UIEventSubtypeRemoteControlBeginSeekingForward:
        [self sendButtonPressed:18];
        break;
      case UIEventSubtypeRemoteControlBeginSeekingBackward:
        [self sendButtonPressed:19];
        break;
      case UIEventSubtypeRemoteControlEndSeekingForward:
      case UIEventSubtypeRemoteControlEndSeekingBackward:
        // restore to normal playback speed.
        if (g_application.m_pPlayer->IsPlaying() && !g_application.m_pPlayer->IsPaused())
          CApplicationMessenger::GetInstance().PostMsg(TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PLAYER_PLAY)));
        break;
      default:
        //LOG(@"unhandled subtype: %d", (int)receivedEvent.subtype);
        break;
    }
    // start remote timeout
    [self startRemoteTimer];
  }
}

#pragma mark - Now Playing routines
//--------------------------------------------------------------
- (void)setIOSNowPlayingInfo:(NSDictionary *)info
{
  PRINT_SIGNATURE();
  self.m_nowPlayingInfo = info;
  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.m_nowPlayingInfo];
}
//--------------------------------------------------------------
- (void)onPlay:(NSDictionary *)item
{
  PRINT_SIGNATURE();
  NSMutableDictionary * dict = [[NSMutableDictionary alloc] init];

  NSString *title = [item objectForKey:@"title"];
  if (title && title.length > 0)
    [dict setObject:title forKey:MPMediaItemPropertyTitle];
  NSString *album = [item objectForKey:@"album"];
  if (album && album.length > 0)
    [dict setObject:album forKey:MPMediaItemPropertyAlbumTitle];
  NSArray *artists = [item objectForKey:@"artist"];
  if (artists && artists.count > 0)
    [dict setObject:[artists componentsJoinedByString:@" "] forKey:MPMediaItemPropertyArtist];
  NSNumber *track = [item objectForKey:@"track"];
  if (track)
    [dict setObject:track forKey:MPMediaItemPropertyAlbumTrackNumber];
  NSNumber *duration = [item objectForKey:@"duration"];
  if (duration)
    [dict setObject:duration forKey:MPMediaItemPropertyPlaybackDuration];
  NSArray *genres = [item objectForKey:@"genre"];
  if (genres && genres.count > 0)
    [dict setObject:[genres componentsJoinedByString:@" "] forKey:MPMediaItemPropertyGenre];

  if (NSClassFromString(@"MPNowPlayingInfoCenter"))
  {
    NSNumber *elapsed = [item objectForKey:@"elapsed"];
    if (elapsed)
      [dict setObject:elapsed forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSNumber *speed = [item objectForKey:@"speed"];
    if (speed)
      [dict setObject:speed forKey:MPNowPlayingInfoPropertyPlaybackRate];
    NSNumber *current = [item objectForKey:@"current"];
    if (current)
      [dict setObject:current forKey:MPNowPlayingInfoPropertyPlaybackQueueIndex];
    NSNumber *total = [item objectForKey:@"total"];
    if (total)
      [dict setObject:total forKey:MPNowPlayingInfoPropertyPlaybackQueueCount];
  }
  /*
   other properities can be set:
   MPMediaItemPropertyAlbumTrackCount
   MPMediaItemPropertyComposer
   MPMediaItemPropertyDiscCount
   MPMediaItemPropertyDiscNumber
   MPMediaItemPropertyPersistentID

   Additional metadata properties:
   MPNowPlayingInfoPropertyChapterNumber;
   MPNowPlayingInfoPropertyChapterCount;
   */

  [self setIOSNowPlayingInfo:dict];
  [dict release];

  m_playbackState = IOS_PLAYBACK_PLAYING;
}
//--------------------------------------------------------------
- (void)OnSpeedChanged:(NSDictionary *)item
{
  PRINT_SIGNATURE();
  if (NSClassFromString(@"MPNowPlayingInfoCenter"))
  {
    NSMutableDictionary *info = [self.m_nowPlayingInfo mutableCopy];
    NSNumber *elapsed = [item objectForKey:@"elapsed"];
    if (elapsed)
      [info setObject:elapsed forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSNumber *speed = [item objectForKey:@"speed"];
    if (speed)
      [info setObject:speed forKey:MPNowPlayingInfoPropertyPlaybackRate];

    [self setIOSNowPlayingInfo:info];
  }
}
//--------------------------------------------------------------
- (void)onPause:(NSDictionary *)item
{
  m_playbackState = IOS_PLAYBACK_PAUSED;
}
//--------------------------------------------------------------
- (void)onStop:(NSDictionary *)item
{
  [self setIOSNowPlayingInfo:nil];

  m_playbackState = IOS_PLAYBACK_STOPPED;
}

#pragma mark - private helper methods
- (void)observeDefaultCenterStuff:(NSNotification *)notification
{
//  LOG(@"default: %@", [notification name]);
//  LOG(@"userInfo: %@", [notification userInfo]);
}

@end
#undef BOOL
