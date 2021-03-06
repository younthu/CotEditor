/*
 ==============================================================================
 CEScriptManager
 
 CotEditor
 http://coteditor.com
 
 Created on 2005-03-12 by nakamuxu
 encoding="UTF-8"
 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2015 1024jp
 
 This program is free software; you can redistribute it and/or modify it under
 the terms of the GNU General Public License as published by the Free Software
 Foundation; either version 2 of the License, or (at your option) any later
 version.
 
 This program is distributed in the hope that it will be useful, but WITHOUT
 ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License along with
 this program; if not, write to the Free Software Foundation, Inc., 59 Temple
 Place - Suite 330, Boston, MA  02111-1307, USA.
 
 ==============================================================================
 */

#import "CEScriptManager.h"
#import "CEConsolePanelController.h"
#import "CEDocument.h"
#import "CEAppDelegate.h"
#import "CEUtils.h"
#import "constants.h"


typedef NS_ENUM(NSUInteger, CEScriptOutputType) {
    CENoOutputType,
    CEReplaceSelectionType,
    CEReplaceAllTextType,
    CEInsertAfterSelectionType,
    CEAppendToAllTextType,
    CEPasteboardType
};

typedef NS_ENUM(NSUInteger, CEScriptInputType) {
    CENoInputType,
    CEInputSelectionType,
    CEInputAllTextType
};


@implementation CEScriptManager

#pragma mark Singleton

// ------------------------------------------------------
/// return singleton instance
+ (instancetype)sharedManager
// ------------------------------------------------------
{
    static dispatch_once_t onceToken;
    static id shared = nil;
    
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    
    return shared;
}



#pragma mark Superclass Methods

// ------------------------------------------------------
/// initialize
- (instancetype)init
// ------------------------------------------------------
{
    self = [super init];
    if (self) {
        [self copySampleScriptToUserDomain:self];
        
        // run dummy AppleScript once for quick script launch
        if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultRunAppleScriptInLaunchingKey]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *source = @"tell application \"CotEditor\" to number of documents";
                NSAppleScript *AppleScript = [[NSAppleScript alloc] initWithSource:source];
                [AppleScript executeAndReturnError:nil];
            });
        }
    }
    return self;
}



#pragma mark Public Methods

//------------------------------------------------------
/// build Script menu
- (void)buildScriptMenu:(id)sender
//------------------------------------------------------
{
    NSMenu *menu = [[[NSApp mainMenu] itemAtIndex:CEScriptMenuIndex] submenu];
    [menu removeAllItems];
    NSMenuItem *menuItem;

    [self addChildFileItemTo:menu fromDir:[[self class] scriptDirectoryURL]];
    
    if ([menu numberOfItems] > 0) {
        menuItem = [NSMenuItem separatorItem];
        [menuItem setTag:CEDefaultScriptMenuItemTag];
        [menu addItem:menuItem];
    }
    
    menuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Open Scripts Folder", nil)
                                          action:@selector(openScriptFolder:)
                                   keyEquivalent:@"a"];
    [menuItem setTarget:self];
    [menuItem setTag:CEDefaultScriptMenuItemTag];
    [menu addItem:menuItem];
    
    menuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Copy Sample to Scripts Folder", nil)
                                          action:@selector(copySampleScriptToUserDomain:)
                                   keyEquivalent:@""];
    [menuItem setTarget:self];
    [menuItem setAlternate:YES];
    [menuItem setKeyEquivalentModifierMask:NSAlternateKeyMask];
    [menuItem setToolTip:NSLocalizedString(@"Copy bundled sample scripts to the scripts folder.", nil)];
    [menuItem setTag:CEDefaultScriptMenuItemTag];
    [menu addItem:menuItem];
    
    menuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Update Script Menu", nil)
                                          action:@selector(buildScriptMenu:)
                                   keyEquivalent:@""];
    [menuItem setTarget:self];
    [menuItem setTag:CEDefaultScriptMenuItemTag];
    [menu addItem:menuItem];
}


//------------------------------------------------------
/// return menu for context menu
- (NSMenu *)contexualMenu
//------------------------------------------------------
{
    NSMenu *menu = [[[[NSApp mainMenu] itemAtIndex:CEScriptMenuIndex] submenu] copy];
    
    for (NSMenuItem *item in [menu itemArray]) {
        if ([item tag] == CEDefaultScriptMenuItemTag) {
            [menu removeItem:item];
        }
    }
    
    return ([menu numberOfItems] > 0) ? menu : nil;
}



#pragma mark Action Messages

//------------------------------------------------------
/// launch script (invoked by menu item)
- (IBAction)launchScript:(id)sender
//------------------------------------------------------
{
    NSURL *URL = [sender representedObject];
    
    if (!URL) { return; }

    // display alert and endup if file not exists
    if (![URL checkResourceIsReachableAndReturnError:nil]) {
        [self showAlertWithMessage:[NSString stringWithFormat:NSLocalizedString(@"The script “%@” does not exist.\n\nCheck it and do “Update Script Menu”.", @""), URL]];
        return;
    }
    
    NSString *extension = [URL pathExtension];

    // change behavior if modifier key is pressed
    NSEventModifierFlags modifierFlags = [NSEvent modifierFlags];
    if (modifierFlags == NSAlternateKeyMask) {  // open script file if Opt key is pressed
        BOOL success = YES;
        NSString *identifier = [[self AppleScriptExtensions] containsObject:extension] ? @"com.apple.ScriptEditor2" : [[NSBundle mainBundle] bundleIdentifier];
        success = [[NSWorkspace sharedWorkspace] openURLs:@[URL]
                                  withAppBundleIdentifier:identifier
                                                  options:0
                           additionalEventParamDescriptor:nil
                                        launchIdentifiers:NULL];
        
        // display alert if cannot open/select the script file
        if (!success) {
            NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Could not open the script file “%@”.", nil), URL];
            [self showAlertWithMessage:message];
        }
        return;
        
    } else if (modifierFlags == (NSAlternateKeyMask | NSShiftKeyMask)) {  // reveal on Finder if Opt+Shift keys are pressed
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[URL]];
        return;
    }

    // run AppleScript
    if ([[self AppleScriptExtensions] containsObject:extension]) {
        [self runAppleScript:URL];
        
    // run Shell Script
    } else if ([[self scriptExtensions] containsObject:extension]) {
        // display alert if script file doesn't have execution permission
        NSNumber *isExecutable;
        [URL getResourceValue:&isExecutable forKey:NSURLIsExecutableKey error:nil];
        if (![isExecutable boolValue]) {
            [self showAlertWithMessage:[NSString stringWithFormat:NSLocalizedString(@"Cannnot execute the script “%@”.\nShell script requires execute permission.\n\nCheck permission of the script file.", nil), URL]];
            return;
        }
        
        [self runShellScript:URL];
    }
}


// ------------------------------------------------------
/// open Script Menu folder in Finder
- (IBAction)openScriptFolder:(id)sender
// ------------------------------------------------------
{
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[CEScriptManager scriptDirectoryURL]]];
}


// ------------------------------------------------------
/// copy sample scripts to user domain
- (IBAction)copySampleScriptToUserDomain:(id)sender
// ------------------------------------------------------
{
    NSURL *sourceURL = [[[NSBundle mainBundle] sharedSupportURL] URLByAppendingPathComponent:@"SampleScripts"];
    NSURL *destURL = [[[self class] scriptDirectoryURL] URLByAppendingPathComponent:@"SampleScript"];
    
    if (![sourceURL checkResourceIsReachableAndReturnError:nil]) {
        return;
    }
    
    if (![destURL checkResourceIsReachableAndReturnError:nil]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:[destURL URLByDeletingLastPathComponent]
                                 withIntermediateDirectories:NO attributes:nil error:nil];
        BOOL success = [[NSFileManager defaultManager] copyItemAtURL:sourceURL toURL:destURL error:nil];
        
        if (success) {
            [self buildScriptMenu:self];
        } else {
            NSLog(@"Error. Sample script folder could not be copied.");
        }
        
    } else if ([sender isKindOfClass:[NSMenuItem class]]) {
        // show alert if sample script folder is already exists only when user performs the copy
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"SampleScript folder exists already.", nil)];
        [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"If you want to replace it with the new one, remove the existing folder at “%@” at first.", nil), [destURL relativePath]]];
        [alert runModal];
    }
}



#pragma mark Private Methods

// ------------------------------------------------------
/// file extensions for UNIX scripts
- (NSArray *)scriptExtensions
// ------------------------------------------------------
{
    return @[@"sh", @"pl", @"php", @"rb", @"py", @"js"];
}


// ------------------------------------------------------
/// file extensions for AppleScript
- (NSArray *)AppleScriptExtensions
// ------------------------------------------------------
{
    return @[@"applescript", @"scpt"];
}


//------------------------------------------------------
/// return directory to save script files
+ (NSURL *)scriptDirectoryURL
//------------------------------------------------------
{
    return [[(CEAppDelegate *)[NSApp delegate] supportDirectoryURL] URLByAppendingPathComponent:@"ScriptMenu"];
}


// ------------------------------------------------------
/// read input type from script
+ (CEScriptInputType)scanInputType:(NSString *)string
// ------------------------------------------------------
{
    NSString *scannedString = nil;
    NSScanner *scanner = [NSScanner scannerWithString:string];
    [scanner setCaseSensitive:YES];
    
    while (![scanner isAtEnd]) {
        [scanner scanUpToString:@"%%%{CotEditorXInput=" intoString:nil];
        if ([scanner scanString:@"%%%{CotEditorXInput=" intoString:nil]) {
            if ([scanner scanUpToString:@"}%%%" intoString:&scannedString]) {
                break;
            }
        }
    }
    
    if ([scannedString isEqualToString:@"Selection"]) {
        return CEInputSelectionType;
        
    } else if ([scannedString isEqualToString:@"AllText"]) {
        return CEInputAllTextType;
    }
    
    return CENoInputType;
}


// ------------------------------------------------------
/// read output type from script
+ (CEScriptOutputType)scanOutputType:(NSString *)string
// ------------------------------------------------------
{
    NSString *scannedString = nil;
    NSScanner *scanner = [NSScanner scannerWithString:string];
    [scanner setCaseSensitive:YES];
    
    while (![scanner isAtEnd]) {
        [scanner scanUpToString:@"%%%{CotEditorXOutput=" intoString:nil];
        if ([scanner scanString:@"%%%{CotEditorXOutput=" intoString:nil]) {
            if ([scanner scanUpToString:@"}%%%" intoString:&scannedString]) {
                break;
            }
        }
    }
    
    if ([scannedString isEqualToString:@"ReplaceSelection"]) {
        return CEReplaceSelectionType;
        
    } else if ([scannedString isEqualToString:@"ReplaceAllText"]) {
        return CEReplaceAllTextType;
        
    } else if ([scannedString isEqualToString:@"InsertAfterSelection"]) {
        return CEInsertAfterSelectionType;
        
    } else if ([scannedString isEqualToString:@"AppendToAllText"]) {
        return CEAppendToAllTextType;
        
    } else if ([scannedString isEqualToString:@"Pasteboard"]) {
        return CEPasteboardType;
    }
    
    return CENoOutputType;
}


// ------------------------------------------------------
/// return document content conforming to the input type
+ (NSString *)inputStringWithType:(CEScriptInputType)inputType document:(CEDocument *)document error:(NSError *__autoreleasing *)outError
// ------------------------------------------------------
{
    CEEditorWrapper *editor = [document editor];
    
    // on no document found
    if (!editor) {
        switch (inputType) {
            case CEInputSelectionType:
            case CEInputAllTextType:
                if (outError) {
                    *outError = [NSError errorWithDomain:CEErrorDomain
                                                    code:CEScriptNoTargetDocumentError
                                                userInfo:@{NSLocalizedDescriptionKey: @"No document to scan input."}];
                }
                return nil;
                
            default:
                break;
        }
    }
    
    switch (inputType) {
        case CEInputSelectionType:
            // ([editor string] は改行コードLFの文字列を返すが、[editor selectedRange] は
            // 改行コードを反映させた範囲を返すので、「CR/LF」では使えない。そのため、
            // [[editor focusedTextView] selectedRange] を使う必要がある。2009-04-12
            return [[editor string] substringWithRange:[[editor focusedTextView] selectedRange]];
            
        case CEInputAllTextType:
            return [editor string];
            
        case CENoInputType:
            return nil;
    }
}


// ------------------------------------------------------
/// apply results conforming to the output type to the frontmost document
+ (BOOL)applyOutput:(NSString *)output document:(CEDocument *)document outputType:(CEScriptOutputType)outputType error:(NSError *__autoreleasing *)outError
// ------------------------------------------------------
{
    CEEditorWrapper *editor = [document editor];
    
    // on no document found
    if (!editor) {
        switch (outputType) {
            case CEReplaceSelectionType:
            case CEReplaceAllTextType:
            case CEInsertAfterSelectionType:
            case CEAppendToAllTextType:
                if (outError) {
                    *outError = [NSError errorWithDomain:CEErrorDomain
                                                    code:CEScriptNoTargetDocumentError
                                                userInfo:@{NSLocalizedDescriptionKey: @"Target document was not found."}];
                }
                return NO;
                
            default:
                break;
        }
    }
    
    switch (outputType) {
        case CEReplaceSelectionType:
            [editor insertTextViewString:output];
            break;
            
        case CEReplaceAllTextType:
            [editor replaceTextViewAllStringWithString:output];
            break;
            
        case CEInsertAfterSelectionType:
            [editor insertTextViewStringAfterSelection:output];
            break;
            
        case CEAppendToAllTextType:
            [editor appendTextViewString:output];
            break;
            
        case CEPasteboardType: {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard declareTypes:@[NSStringPboardType] owner:nil];
            if (![pasteboard setString:output forType:NSStringPboardType]) {
                NSBeep();
            }
            break;
        }
        case CENoOutputType:
            break;  // do nothing
    }
    
    return YES;
}


//------------------------------------------------------
/// read files and create/add menu items
- (void)addChildFileItemTo:(NSMenu *)menu fromDir:(NSURL *)directoryURL
//------------------------------------------------------
{
    NSArray *URLs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directoryURL
                                                  includingPropertiesForKeys:@[NSURLFileResourceTypeKey]
                                                                     options:NSDirectoryEnumerationSkipsPackageDescendants | NSDirectoryEnumerationSkipsHiddenFiles
                                                                       error:nil];
    
    for (NSURL *URL in URLs) {
        // ignore files/folders of which name starts with "_"
        if ([[URL lastPathComponent] hasPrefix:@"_"]) {  continue; }
        
        NSString *resourceType;
        NSString *extension = [URL pathExtension];
        [URL getResourceValue:&resourceType forKey:NSURLFileResourceTypeKey error:nil];
        
        if ([resourceType isEqualToString:NSURLFileResourceTypeDirectory]) {
            NSString *title = [self scriptNameFromURL:URL];
            if ([title isEqualToString:@"-"]) {  // separator
                [menu addItem:[NSMenuItem separatorItem]];
                continue;
            }
            NSMenu *subMenu = [[NSMenu alloc] initWithTitle:title];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
            [item setTag:CEScriptMenuDirectoryTag];
            [menu addItem:item];
            [item setSubmenu:subMenu];
            [self addChildFileItemTo:subMenu fromDir:URL];
            
        } else if ([resourceType isEqualToString:NSURLFileResourceTypeRegular] &&
                   ([[self AppleScriptExtensions] containsObject:extension] || [[self scriptExtensions] containsObject:extension]))
        {
            NSUInteger modifierMask = 0;
            NSString *keyEquivalent = [self keyEquivalentAndModifierMask:&modifierMask fromFileName:[URL lastPathComponent]];
            NSString *title = [self scriptNameFromURL:URL];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                          action:@selector(launchScript:)
                                                   keyEquivalent:keyEquivalent];
            [item setKeyEquivalentModifierMask:modifierMask];
            [item setRepresentedObject:URL];
            [item setTarget:self];
            [item setToolTip:NSLocalizedString(@"“Opt + click” to open in Script Editor.", nil)];
            [menu addItem:item];
        }
    }
}


//------------------------------------------------------
/// ファイル／フォルダ名からメニューアイテムタイトル名を生成
- (NSString *)scriptNameFromURL:(NSURL *)URL
//------------------------------------------------------
{
    NSString *fileName = [URL lastPathComponent];
    NSString *scriptName = [fileName stringByDeletingPathExtension];
    NSString *extnFirstChar = [[scriptName pathExtension] substringFromIndex:0];
    NSCharacterSet *specSet = [NSCharacterSet characterSetWithCharactersInString:@"^~$@"];

    // remove the number prefix ordering
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+\\)"
                                                                           options:0 error:nil];
    scriptName = [regex stringByReplacingMatchesInString:scriptName
                                                options:0
                                                  range:NSMakeRange(0, [scriptName length])
                                           withTemplate:@""];
    
    // remove keyboard shortcut definition
    if (([extnFirstChar length] > 0) && [specSet characterIsMember:[extnFirstChar characterAtIndex:0]]) {
        scriptName = [scriptName stringByDeletingPathExtension];
    }
    
    return scriptName;
}


//------------------------------------------------------
/// get keyboard shortcut from file name
- (NSString *)keyEquivalentAndModifierMask:(NSUInteger *)modifierMask fromFileName:(NSString *)fileName
//------------------------------------------------------
{
    NSString *keySpec = [[fileName stringByDeletingPathExtension] pathExtension];

    return [CEUtils keyEquivalentAndModifierMask:modifierMask fromString:keySpec includingCommandKey:YES];
}


//------------------------------------------------------
/// display alert message
- (void)showAlertWithMessage:(NSString *)message
//------------------------------------------------------
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"Script Error", nil)];
    [alert setInformativeText:message];
    [alert setAlertStyle:NSCriticalAlertStyle];
    [alert runModal];
}


//------------------------------------------------------
/// read content of script file
- (NSString *)stringOfScript:(NSURL *)URL
//------------------------------------------------------
{
    NSData *data = [NSData dataWithContentsOfURL:URL];
    
    if ([data length] == 0) { return nil; }
    
    NSArray *encodings = [[NSUserDefaults standardUserDefaults] arrayForKey:CEDefaultEncodingListKey];
    
    for (NSNumber *encodingNumber in encodings) {
        NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding([encodingNumber unsignedLongValue]);
        NSString *scriptString = [[NSString alloc] initWithData:data encoding:encoding];
        if (scriptString) {
            return scriptString;
        }
    }
    
    return nil;
}


//------------------------------------------------------
/// run AppleScript
- (void)runAppleScript:(NSURL *)URL
//------------------------------------------------------
{
    NSError *error = nil;
    NSUserAppleScriptTask *task = [[NSUserAppleScriptTask alloc] initWithURL:URL error:&error];
    
    [task executeWithAppleEvent:nil completionHandler:^(NSAppleEventDescriptor *result, NSError *error) {
        if (error) {
            [self showAlertWithMessage:[error localizedDescription]];
        }
    }];
}


//------------------------------------------------------
/// run UNIX script
- (void)runShellScript:(NSURL *)URL
//------------------------------------------------------
{
    NSError *error = nil;
    NSUserUnixTask *task = [[NSUserUnixTask alloc] initWithURL:URL error:&error];
    NSString *script = [self stringOfScript:URL];
    NSString *scriptName = [self scriptNameFromURL:URL];

    // show an alert and endup if script file cannot read
    if (!task || [script length] == 0) {
        [self showAlertWithMessage:[NSString stringWithFormat:NSLocalizedString(@"Could not read the script “%@”.", nil), URL]];
        return;
    }
    
    // hold target document
    __weak CEDocument *document = [[NSDocumentController sharedDocumentController] currentDocument];

    // read input
    CEScriptInputType inputType = [[self class] scanInputType:script];
    NSError *inputError = nil;
    __block NSString *input = [[self class] inputStringWithType:inputType document:document error:&inputError];
    if (inputError) {
        [self showScriptError:[inputError localizedDescription] scriptName:scriptName];
        return;
    }
    
    // get output type
    CEScriptOutputType outputType = [[self class] scanOutputType:script];
    
    // prepare file path as argument if available
    NSArray *arguments;
    if ([document fileURL]) {
        arguments = @[[[document fileURL] path]];
    }
    
    __weak typeof(self) weakSelf = self;
    __block BOOL cancelled = NO;  // user cancel state
    
    // pipes
    NSPipe *inPipe = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    [task setStandardInput:[inPipe fileHandleForReading]];
    [task setStandardOutput:[outPipe fileHandleForWriting]];
    [task setStandardError:[errPipe fileHandleForWriting]];
    
    // set input data asynchronously if available
    if ([input length] > 0) {
        [[inPipe fileHandleForWriting] setWriteabilityHandler:^(NSFileHandle *handle) {
            NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
            [handle writeData:data];
            [handle closeFile];
        }];
    }
    
    // read output asynchronously for safe with huge output
    [[outPipe fileHandleForReading] readToEndOfFileInBackgroundAndNotify];
    __block id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleReadToEndOfFileCompletionNotification
                                                                    object:[outPipe fileHandleForReading]
                                                                     queue:nil
                                                                usingBlock:^(NSNotification *note)
     {
         [[NSNotificationCenter defaultCenter] removeObserver:observer];
         
         if (cancelled) { return; }
         
         typeof(weakSelf) strongSelf = weakSelf;
         NSData *data = [note userInfo][NSFileHandleNotificationDataItem];
         NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
         if (output) {
             NSError *error;
             [CEScriptManager applyOutput:output document:document outputType:outputType error:&error];
             if (error) {
                 [strongSelf showScriptError:[error localizedDescription] scriptName:scriptName];
             }
         }
     }];
    
    // execute
    [task executeWithArguments:arguments completionHandler:^(NSError *error)
     {
        // on user cancel
        if ([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == ENOTBLK) {
            cancelled = YES;
            return;
        }
        
        NSData *errorData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errorMsg = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        if ([errorMsg length] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                [strongSelf showScriptError:errorMsg scriptName:scriptName];
            });
        }
    }];
}


// ------------------------------------------------------
/// append message to console panel and show it
- (void)showScriptError:(NSString *)errorString scriptName:(NSString *)scriptName
// ------------------------------------------------------
{
    [[CEConsolePanelController sharedController] showWindow:self];
    [[CEConsolePanelController sharedController] appendMessage:errorString title:scriptName];
}

@end
