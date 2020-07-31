//
//  PtpWebcamPtpDevice.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPtpDevice.h"
#import "PtpWebcamPtpStream.h"
#import "PtpWebcamAlerts.h"
#import "PtpWebcamPtp.h"


@interface PtpWebcamPtpDevice ()
{
	uint32_t transactionId;
	NSStatusItem* statusItem;
	BOOL isPropertyExplorerEnabled;
}
@end

@implementation PtpWebcamPtpDevice


- (instancetype) initWithCamera: (PtpCamera*) camera pluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
		
	self.camera = camera;
	camera.delegate = self;
		
	self.name = camera.model;
	self.manufacturer = camera.make;
	self.elementNumberName = @"1";
	self.elementCategoryName = @"DSLR Webcam";
	self.deviceUid = camera.cameraId;
	self.modelUid = [NSString stringWithFormat: @"ptp-webcam-plugin-model-%@", camera.model];

	isPropertyExplorerEnabled = [[NSProcessInfo processInfo].environment[@"PTPWebcamPropertyExplorerEnabled"] isEqualToString: @"YES"];

	// camera has been ready for use at this point
	[self queryAllCameraProperties];
	
	return self;
}

- (PtpWebcamPtpStream*) ptpStream
{
	return (id)self.stream;
}


// MARK: PTP Camera Delegate

- (void) cameraDidBecomeReadyForUse: (PtpCamera*) camera
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[self rebuildStatusItem];
	});
}

- (void) cameraDidBecomeReadyForLiveViewStreaming:(PtpCamera *)camera
{
	[self.ptpStream cameraDidBecomeReadyForLiveViewStreaming];
}

- (void) receivedLiveViewJpegImage:(NSData *)jpegData withInfo:(NSDictionary *)info fromCamera:(PtpCamera *)camera
{
	[self.ptpStream receivedLiveViewJpegImageData: jpegData withInfo: info];
}

- (void) receivedCameraProperty:(NSDictionary *)propertyInfo withId:(NSNumber *)propertyId fromCamera:(PtpCamera *)camera
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[self rebuildStatusItem];
	});

}

- (void) cameraWasRemoved:(PtpCamera *)camera
{
	[self unplugDevice];
}


- (void) unplugDevice
{
	[self.stream unplugDevice];

	[self removeStatusItem];

	[self deleteCmioDevice];
	
}

// MARK: User Interface

- (void) queryAllCameraProperties
{
	// if property explorer is enabled, query all properties, else only query properties that are supposed to show up in the UI
	if (isPropertyExplorerEnabled)
	{
		for (id propertyId in self.camera.ptpDeviceInfo[@"properties"])
		{
			[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
		}
	}
	else
	{
		for (id propertyId in self.camera.uiPtpProperties)
		{
			if ([self.camera.ptpDeviceInfo[@"properties"] containsObject: propertyId])
				[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
		}
	}

}


- (void) createStatusItem
{
	// blacklist some processes from creating status items to weed out the worst offenders
	if (PtpWebcamIsProcessGuiBlacklisted())
		return;
	

	// do not create status item if stream isn't running to avoid duplicates for apps with multiple processes accessing DAL plugins

	if (!statusItem)
		statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];

	// The text that will be shown in the menu bar
	statusItem.button.title = self.name;
	
	// we could set an image, but the text somehow makes more sense
//	NSBundle *otherBundle = [NSBundle bundleWithIdentifier: @"net.monkeyinthejungle.ptpwebcamdalplugin"];
//	NSImage *image = [otherBundle imageForResource: @"ptpwebcam-logo-22x22"];
//	statusItem.button.image = image;

	// The image that will be shown in the menu bar, a 16x16 black png works best
//	_statusItem.image = [NSImage imageNamed:@"feedbin-logo"];

	// The highlighted image, use a white version of the normal image
//	_statusItem.alternateImage = [NSImage imageNamed:@"feedbin-logo-alt"];

	// The image gets a blue background when the item is selected
//	statusItem.highlightMode = YES;

}

- (void) removeStatusItem
{
	
	[[NSStatusBar systemStatusBar] removeStatusItem: statusItem];
	statusItem = nil;
	
}

- (NSString*) formatValue: (id) value ofType: (int) propertyId
{
	NSString* valueString = [NSString stringWithFormat:@"%@", value];
	
	switch (propertyId)
	{
		case PTP_PROP_BATTERYLEVEL:
			valueString = [NSString stringWithFormat: @"%.0f %%", [value doubleValue]];
			break;
		case PTP_PROP_FNUM:
			valueString = [NSString stringWithFormat: @"%.1f", 0.01*[value doubleValue]];
			break;
		case PTP_PROP_FOCUSDISTANCE:
			valueString = [NSString stringWithFormat: @"%.0f mm", [value doubleValue]];
			break;
		case PTP_PROP_EXPOSUREBIAS:
			valueString = [NSString stringWithFormat: @"%.3f", 0.001*[value doubleValue]];
			break;
		case PTP_PROP_FLEN:
			valueString = [NSString stringWithFormat: @"%.2f mm", 0.01*[value doubleValue]];
			break;
		case PTP_PROP_EXPOSURETIME:
		{
			double exposureTime = 0.0001*[value doubleValue];
			// FIXME: exposure times like 1/10000 vs. 1/8000 cannot be distinguished do to PTP property resolution of 0.0001s
			if (exposureTime < 1.0)
			{
				valueString = [NSString stringWithFormat: @"1/%.0f s", 1.0/exposureTime];
			}
			else
			{
				valueString = [NSString stringWithFormat: @"%.1f s", exposureTime];
			}
			break;
		}
		case PTP_PROP_NIKON_LV_STATUS:
		case PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW:
		{
			valueString = [value boolValue] ? @"On" : @"Off";
			break;
		}
		case PTP_PROP_NIKON_SHUTTERSPEED:
		{
			uint32_t val = [value unsignedIntValue];
			uint16_t nom = val >> 16;
			uint16_t den = val & 0x0000FFFF;
			if (val == 0xFFFFFFFF)
			{
				valueString = @"Bulb";
			}
			else if (val == 0xFFFFFFFE)
			{
				valueString = @"Flash";
			}
			else if ((den == 10) && (nom != 1))
			{
				valueString = [NSString stringWithFormat:@"%.1f s", 0.1*nom];
			}
			else if ((nom == 10) && (den != 1))
			{
				valueString = [NSString stringWithFormat:@"1/%.1f s", 0.1*den];
			}
			else if (den > 1)
			{
				valueString = [NSString stringWithFormat:@"%u/%u s", nom, den];
			}
			else
			{
				valueString = [NSString stringWithFormat:@"%u s", nom];
			}
			break;
		}
		default:
		{
			NSDictionary* valueNames = self.camera.ptpPropertyValueNames[@(propertyId)];
			NSString* name = [valueNames objectForKey: value];
			
			// if we have names for the property, but not this special value, show hex code
			if (!name && valueNames)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			if (name)
				valueString = name;

			break;
		}
	}

	return valueString;
}

- (NSMenu*) buildSubMenuForPropertyInfo: (NSDictionary*) property withId: (NSNumber*) propertyId interactive: (BOOL) isInteractive
{
	NSMenu* submenu = [[NSMenu alloc] init];
	id value = property[@"value"];
	if ([property[@"range"] isKindOfClass: [NSArray class]])
	{
		NSArray* values = property[@"range"];
		
		for (id enumVal in values)
		{
			NSString* valStr = [self formatValue: enumVal ofType: propertyId.intValue];

			NSMenuItem* subItem = [[NSMenuItem alloc] init];
			subItem.title =  valStr;
			if (isInteractive)
			{
				subItem.target = self;
				subItem.action =  @selector(changeCameraPropertyAction:);
				subItem.tag = propertyId.integerValue;
				subItem.representedObject = enumVal;
			}
			
			if ([value isEqual: enumVal])
				subItem.state = NSControlStateValueOn;
			
			[submenu addItem: subItem];

		}
	}
	else if (property[@"range"]) // Range is a range (min, max, step)
	{
		NSDictionary* rangeInfo = property[@"range"];
		long long rmin = [rangeInfo[@"min"] intValue];
		long long rmax = [rangeInfo[@"max"] intValue];
		long long step = [rangeInfo[@"step"] intValue];
		size_t count = (rmax-rmin+1)/step;
		if (count <= 50)
		{
			for (long long i = rmin; i <= rmax; ++i)
			{
				NSMenuItem* subItem = [[NSMenuItem alloc] init];
				NSString* valStr = [self formatValue: @(i) ofType: propertyId.intValue];
				subItem.title = valStr;
				
				if ([value isEqual: @(i)])
					subItem.state = NSControlStateValueOn;
				
				if (isInteractive)
				{
					subItem.target = self;
					subItem.action =  @selector(changeCameraPropertyAction:);
					subItem.tag = propertyId.integerValue;
					subItem.representedObject = @(i);

				}
				[submenu addItem: subItem];
			}
		}
		else
		{
			NSMenuItem* subItem = [[NSMenuItem alloc] init];
			subItem.title =  [NSString stringWithFormat: @"Property Range: %@", property[@"range"]];
			[submenu addItem: subItem];

		}
	}
	else
	{
		NSMenuItem* subItem = [[NSMenuItem alloc] init];
		subItem.title =  @"(Property has available no range)";
		[submenu addItem: subItem];

	}
	return submenu;
}

- (void) rebuildStatusItem
{
	if (!statusItem)
	{
		[self createStatusItem];
	}
		
	
	NSMenu* menu = [[NSMenu alloc] init];
	NSDictionary* ptpPropertyNames = [self.camera ptpPropertyNames];

//	if (isPropertyExplorerEnabled)
	{
		NSString *processName = [[NSProcessInfo processInfo] processName];
		
		NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"controlled from \"%@\"", processName] action: NULL keyEquivalent: @""];
		menuItem.target = self;
		menuItem.action =  @selector(nopAction:);

		[menu addItem: menuItem];
		[menu addItem: [NSMenuItem separatorItem]];
	}

	for (id propertyId in self.camera.uiPtpProperties)
	{
		
		if ([propertyId isEqual: @"-"])
		{
			[menu addItem: [NSMenuItem separatorItem]];
		}
		else
		{
			NSString* name = ptpPropertyNames[propertyId];
			if (!name)
				continue;
			NSDictionary* property = self.camera.ptpPropertyInfos[propertyId];

			id value = property[@"value"];
			NSString* valueString = [self formatValue: value ofType: [propertyId intValue]];
			
			NSMenuItem* menuItem = [[NSMenuItem alloc] init];
			[menuItem setTitle: [NSString stringWithFormat: @"%@ (%@)", name, valueString]];
			
			// add submenus for writable items
			if ([property[@"rw"] boolValue])
			{
				if (property[@"range"])
				{
					NSMenu* submenu = [self buildSubMenuForPropertyInfo: property withId: propertyId interactive: YES];
					
					menuItem.submenu = submenu;
				}
			}
			else
			{
				// assign dummy action so items aren't grayed out
				menuItem.target = self;
				menuItem.action =  @selector(nopAction:);
			}

			[menu addItem: menuItem];
		}
	}
	
	// add autofocus command
	if ([self.camera.ptpDeviceInfo[@"operations"] containsObject: @(PTP_CMD_NIKON_AFDRIVE)])
	{
		[menu addItem: [NSMenuItem separatorItem]];
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"Autofocus…";
		item.target = self;
		item.action =  @selector(autofocusAction:);
		[menu addItem: item];
	}
	
	// camera properties
	if (isPropertyExplorerEnabled)
	{
		[menu addItem: [NSMenuItem separatorItem]];
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"PTP Properties";

		NSMenu* submenu = [[NSMenu alloc] init];
		NSArray* properties = self.camera.ptpDeviceInfo[@"properties"];
		
		NSDictionary* propertyNames = self.camera.ptpPropertyNames;
		NSDictionary* propertyInfos = self.camera.ptpPropertyInfos;
		
		for (NSNumber* propertyId in properties)
		{
			
			NSDictionary* propertyInfo = propertyInfos[propertyId];
			
			NSString* name = propertyNames[propertyId];
			NSString* valStr = nil;
			if (name)
				valStr = [NSString stringWithFormat: @"0x%04X %@ = %@ (%@)", propertyId.unsignedIntValue, name, propertyInfo[@"defaultValue"], propertyInfo[@"value"]];
			else
				valStr = [NSString stringWithFormat: @"0x%04X = %@ (%@)", propertyId.unsignedIntValue, propertyInfo[@"defaultValue"], propertyInfo[@"value"]];

			NSMenuItem* subItem = [[NSMenuItem alloc] init];
			subItem.title =  valStr;
			
			NSMenu* subsubmenu = [self buildSubMenuForPropertyInfo: propertyInfo withId: propertyId interactive: NO];
			
			subItem.submenu = subsubmenu;

			[submenu addItem: subItem];

		}
		
		item.submenu = submenu;



		[menu addItem: item];

	}
	// operations
	if (isPropertyExplorerEnabled)
	{
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"PTP Operations";

		NSMenu* submenu = [[NSMenu alloc] init];
		NSArray* operations = self.camera.ptpDeviceInfo[@"operations"];
		NSDictionary* operationNames = self.camera.ptpOperationNames;
		
		for (NSNumber* operationId in operations)
		{
			
			NSString* valStr = [NSString stringWithFormat: @"0x%04X %@", operationId.unsignedIntValue, operationNames[operationId]];

			NSMenuItem* subItem = [[NSMenuItem alloc] init];
			subItem.title =  valStr;
			
			[submenu addItem: subItem];

		}
		
		item.submenu = submenu;



		[menu addItem: item];

	}

	statusItem.menu = menu;

}
- (IBAction) autofocusAction:(NSMenuItem*)sender
{
	[self.camera requestSendPtpCommandWithCode: PTP_CMD_NIKON_AFDRIVE];
}

- (IBAction) changeCameraPropertyAction:(NSMenuItem*)sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	
	[self.camera ptpSetProperty: propertyId toValue: sender.representedObject];

	[self.camera ptpQueryKnownDeviceProperties];
}

- (IBAction) nopAction:(NSMenuItem*)sender
{
	// do nothing, this only exists so that menu items aren't grayed out
}


@end
