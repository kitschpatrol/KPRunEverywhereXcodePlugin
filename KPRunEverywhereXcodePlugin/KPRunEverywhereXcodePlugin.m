//
//  RunEverywhereXcodePlugin.m
//  RunEverywhereXcodePlugin
//
//  Created by Eric Mika on 3/19/14.
//  Copyright (c) 2014 Kitschpatrol. All rights reserved.
//

#import "KPRunEverywhereXcodePlugin.h"

static KPRunEverywhereXcodePlugin *sharedPlugin;

@interface KPRunEverywhereXcodePlugin ()

@property (nonatomic, strong) NSBundle *bundle;

@property (nonatomic, strong) NSString *initiallySelectedDestinationTitle;
@property (nonatomic, strong) NSMutableArray *destinationTitlesToBuild;

// Guards prevent multiple builds on redundant notifications
@property (nonatomic) BOOL waitingForBuild;
@property (nonatomic) BOOL waitingForRun;
@property (nonatomic) BOOL waitingForStop;

@end

@implementation KPRunEverywhereXcodePlugin

+ (void)pluginDidLoad:(NSBundle *)plugin {
  static id sharedPlugin = nil;
  static dispatch_once_t onceToken;
  NSString *currentApplicationName = [[NSBundle mainBundle] infoDictionary][@"CFBundleName"];
  if ([currentApplicationName isEqual:@"Xcode"]) {
    dispatch_once(&onceToken, ^{
      sharedPlugin = [[self alloc] initWithBundle:plugin];
    });
  }
}

- (id)initWithBundle:(NSBundle *)plugin {
  if (self = [super init]) {
    // Reference to plugin's bundle, for resource acccess
    self.bundle = plugin;

    _waitingForBuild = NO;
    _waitingForRun = NO;
    _waitingForStop = NO;
    _destinationTitlesToBuild = nil;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidFinishLaunching:)
                                                 name:NSApplicationDidFinishLaunchingNotification
                                               object:nil];

    // Watch notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notificationListener:) name:nil object:nil];
  }
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  // Set up menu items
  NSMenuItem *productMenuItem = [[NSApp mainMenu] itemWithTitle:@"Product"];
  if (productMenuItem) {
    // Run everywhere item
    NSMenuItem *runEverywhereMenuItem = [[NSMenuItem alloc] initWithTitle:@"Run Everywhere" action:@selector(doRunEverywhereMenuAction) keyEquivalent:@"r"];
    [runEverywhereMenuItem setKeyEquivalentModifierMask:NSCommandKeyMask | NSControlKeyMask | NSAlternateKeyMask];
    [runEverywhereMenuItem setAlternate:NO];
    [runEverywhereMenuItem setTarget:self];

    // Add it to the product menu
    NSInteger runMenuItemIndex = [[productMenuItem submenu] indexOfItemWithTitle:@"Run"];
    [[productMenuItem submenu] insertItem:runEverywhereMenuItem atIndex:runMenuItemIndex + 2]; // Deal with hidden alternate "Run..." menu item.

    // Stop everywhere item
    NSMenuItem *stopEverywhereMenuItem = [[NSMenuItem alloc] initWithTitle:@"Stop Everywhere" action:@selector(doStopEverywhereMenuAction) keyEquivalent:@"."];
    [stopEverywhereMenuItem setKeyEquivalentModifierMask:NSCommandKeyMask | NSControlKeyMask | NSAlternateKeyMask];
    [stopEverywhereMenuItem setAlternate:NO];
    [stopEverywhereMenuItem setTarget:self];

    // Add it to the product menu
    NSInteger stopMenuItemIndex = [[productMenuItem submenu] indexOfItemWithTitle:@"Stop"];
    [[productMenuItem submenu] insertItem:stopEverywhereMenuItem atIndex:stopMenuItemIndex + 1];
  }

  [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidFinishLaunchingNotification object:nil];
}

- (void)notificationListener:(NSNotification *)notification {
  /*
   // Log notifications if you like
   if ([[notification name] length] >= 2 && ([[[notification name] substringWithRange:NSMakeRange(0, 2)] isEqualTo:@"NS"] || [[[notification name]
   substringWithRange:NSMakeRange(0, 2)] isEqualTo:@"_N"])) {
   // It's a system-level notification
   }
   else {
   // It's a Xcode-level notification
   NSLog(@"%@", notification.name);
   }
   */

  // This seems like quite a mess, but the notification-driven approach avoids waiting for
  // indeterminate amounts of time for building / running to get far enough along to avoid crashes.

  // Finished building
  if ([[notification name] isEqualToString:@"IDEBuildOperationDidGenerateOutputFilesNotification"]) {
    if (self.waitingForBuild) {
      self.waitingForBuild = NO;
      [self runSelected];

      // Clean up if it's the end of the list
      if (self.destinationTitlesToBuild.count == 0) {
        self.destinationTitlesToBuild = nil;
        self.waitingForBuild = NO;
        self.waitingForRun = NO;
        [self performActionForMenuItemWithTitle:self.initiallySelectedDestinationTitle];
      }
    }
  }

  // Finished launching
  if ([[notification name] isEqualToString:@"DVTDeviceShouldIgnoreChangesDidEndNotification"]) {
    if (self.waitingForRun) {
      self.waitingForRun = NO;
      [self buildNextDestination];
    }
  }

  // Finished stopping
  if ([[notification name] isEqualToString:@"CurrentExecutionTrackerCompletedNotification"]) {
    if (self.waitingForStop) {
      // Keep stopping
      self.waitingForStop = NO;
      [self doStopEverywhereMenuAction];
    }
  }
}

#pragma mark - Menu Callbacks

- (void)doStopEverywhereMenuAction {
  [self updateMenus];
  self.waitingForStop = NO;

  NSMenuItem *productMenuItem = [[NSApp mainMenu] itemWithTitle:@"Product"];
  NSMenuItem *stopMenuItem = [[productMenuItem submenu] itemWithTitle:@"Stop"];
  [[productMenuItem submenu] update];

  if ([stopMenuItem isEnabled]) {
    self.waitingForStop = YES;
    [self performActionForMenuItem:stopMenuItem];
  }
}

// Sample Action, for menu item:
- (void)doRunEverywhereMenuAction {
  self.waitingForBuild = NO;
  self.waitingForRun = NO;

  self.destinationTitlesToBuild = [NSMutableArray arrayWithArray:[self getDestinationMenuItemTitles]];

  // TODO stop everything
  // Save initially selected item
  self.initiallySelectedDestinationTitle = nil;
  for (NSString *destinationTitle in self.destinationTitlesToBuild) {
    NSMenuItem *destinationMenuItem = [self getDestinationMenuByTitle:destinationTitle];
    if (destinationMenuItem.state == NSOnState) {
      self.initiallySelectedDestinationTitle = destinationMenuItem.title;
      break;
    }
  }

  [self buildNextDestination];
  // Notifications kick off the rest
}

#pragma mark - Logic

- (void)buildNextDestination {
  if (self.destinationTitlesToBuild) {
    if (self.destinationTitlesToBuild.count > 0) {
      // Run next
      NSString *destinationToBuildTitle = [self.destinationTitlesToBuild lastObject];
      [self.destinationTitlesToBuild removeLastObject];

      // Select destination
      [self performActionForMenuItemWithTitle:destinationToBuildTitle];
      [self buildSelected];
    }
  }
}

- (void)buildSelected {
  self.waitingForBuild = YES;
  NSMenuItem *buildMenuItem;
  NSMenuItem *productMenuItem = [[NSApp mainMenu] itemWithTitle:@"Product"];
  if ([productMenuItem hasSubmenu]) {
    buildMenuItem = [[productMenuItem submenu] itemWithTitle:@"Build"];
  }

  [self performActionForMenuItem:buildMenuItem];
}

- (void)runSelected {
  self.waitingForRun = YES;
  // Run it
  NSMenuItem *runMenuItem;
  NSMenuItem *productMenuItem = [[NSApp mainMenu] itemWithTitle:@"Product"];
  if ([productMenuItem hasSubmenu]) {
    runMenuItem = [[productMenuItem submenu] itemWithTitle:@"Run"];
  }
  [self performActionForMenuItem:runMenuItem];
}

- (void)performActionForMenuItemWithTitle:(NSString *)title {
  // Run UI stuff on the main thread
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateMenus];
    NSMenuItem *menuItem = [self getDestinationMenuByTitle:title];
    [[menuItem menu] performActionForItemAtIndex:[[menuItem menu] indexOfItem:menuItem]];
  });
}

- (void)performActionForMenuItem:(NSMenuItem *)menuItem {
  // Run UI stuff on the main thread
  dispatch_async(dispatch_get_main_queue(), ^{
    [[menuItem menu] performActionForItemAtIndex:[[menuItem menu] indexOfItem:menuItem]];
  });
}

#pragma mark - Helpers

- (NSMenuItem *)getDestinationMenuByTitle:(NSString *)title {
  NSMenuItem *productMenuItem = [[NSApp mainMenu] itemWithTitle:@"Product"];
  if ([productMenuItem hasSubmenu]) {
    NSMenuItem *destinationMenuItem = [[productMenuItem submenu] itemWithTitle:@"Destination"];
    if ([destinationMenuItem hasSubmenu]) {
      return [[destinationMenuItem submenu] itemWithTitle:title];
    }
  }
  return nil;
}

- (void)updateMenus {
  // According to dtrace the destinations list is generated lazily when the menu is opened
  // This ensures the list is populated before we scan for destinations
  [[[NSApp mainMenu] delegate] menuNeedsUpdate:[NSApp mainMenu]];

  NSMenuItem *productMenuItem = [[NSApp mainMenu] itemWithTitle:@"Product"];
  // NSMenu *productMenu = [productMenuItem submenu];
  //[[productMenu delegate] menuNeedsUpdate:productMenu];

  if ([productMenuItem hasSubmenu]) {
    NSMenuItem *destinationMenuItem = [[productMenuItem submenu] itemWithTitle:@"Destination"];
    if ([destinationMenuItem hasSubmenu]) {
      NSMenu *destinationMenu = [destinationMenuItem submenu];
      [[destinationMenu delegate] menuNeedsUpdate:destinationMenu];
    }
  }
}

- (NSArray *)getDestinationMenuItemTitles {
  // Fish out the destination menu items
  NSMutableArray *destinationItems = [NSMutableArray array];

  [self updateMenus];

  NSMenuItem *productMenuItem = [[NSApp mainMenu] itemWithTitle:@"Product"];

  if ([productMenuItem hasSubmenu]) {
    NSMenuItem *destinationMenuItem = [[productMenuItem submenu] itemWithTitle:@"Destination"];

    if ([destinationMenuItem hasSubmenu]) {
      BOOL foundFirstSeparator = NO;

      for (NSMenuItem *menuItem in [[destinationMenuItem submenu] itemArray]) {
        // Grab everything after first separator, and before second separator or end of the menu
        if ([menuItem isSeparatorItem]) {
          if (!foundFirstSeparator) {
            foundFirstSeparator = YES;
          } else {
            break;
          }
        } else if (foundFirstSeparator) {
          [destinationItems addObject:menuItem.title];
        }
      }
    }
  }

  return [destinationItems copy];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
