//
//  Container.m
//  TestDynamicProxy
//
//  Created by tobias patton on 7/27/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import "OCIOCContainer.h"
#include "OCIOCPropertyUtils.h"
#import <objc/runtime.h>

@interface OCIOCContainer(PrivateMethods)
- (void) registerName:(NSString *)name withInitializer:(InitializerBlock)initializer andMode:(const NSString *)mode;
- (NSArray *) registeredInterceptorsForClass: (Class)class;
- (id) newInstanceOfName: (NSString *)name;
- (void) addInterceptorsToProxy: (id) proxy;
- (NSString *) defaultSetterForProperty: (NSString *)property;
@end

@implementation OCIOCContainer

const NSString *modeShared = @"ModeShared";
const NSString *modeNonShared = @"ModeNonShared";

static OCIOCContainer *gContainer;

+ (void)initialize
{
    if(gContainer == nil)
    {
        gContainer = [[OCIOCContainer alloc] init];
    }    
}

+ (OCIOCContainer *) sharedContainer
{
    return gContainer;
}

@synthesize RegisteredClasses;
@synthesize RegisteredInterceptors;
@synthesize Singletons;

- (id) init
{
    if(self = [super init])
    {        
        RegisteredClasses = [[NSMutableDictionary alloc] init];
        RegisteredInterceptors = [[NSMutableDictionary alloc] init];
        Singletons = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void) dealloc
{
    [RegisteredClasses release];
    [RegisteredInterceptors release];
    [Singletons release];
    [super dealloc];
}

- (void) registerProtocol:(Protocol *)proto withInitializer:(InitializerBlock)initializer andMode:(const NSString *)mode
{
    [self registerName:NSStringFromProtocol(proto) withInitializer:initializer andMode:mode];    
}

- (void) registerClass: (Class)class withInitializer:(InitializerBlock)initializer andMode:(const NSString *)mode;
{
    [self registerName:NSStringFromClass(class) withInitializer:initializer andMode:mode];
}

- (void) registerName:(NSString *)name withInitializer:(InitializerBlock)initializer andMode:(const NSString *)mode
{
    if(mode == modeShared)
    {
        id instance = initializer();
        [Singletons setObject:instance forKey:name];  
        // Copy the block. It is stack object and will be invalidted when the stack from is popped.
        InitializerBlock block = [[^(){return [[Singletons valueForKey:name] retain];} copy] autorelease];
        [RegisteredClasses setObject:block forKey:name];    
    }
    else 
    {
        [RegisteredClasses setObject:initializer forKey:name];    
    }
}

- (void) registerInterceptor: (id<OCIOCIntercepting>)interceptor forProtocol: (Protocol *)proto;
{
    [RegisteredInterceptors setObject:interceptor forKey:NSStringFromProtocol(proto)];
}

- (id<OCIOCIntercepting>) InterceptorForProtocol: (Protocol *)proto
{
    return [RegisteredInterceptors valueForKey:NSStringFromProtocol(proto)];
}

- (NSArray *) registeredInterceptorsForClass: (Class)class
{
    NSMutableArray *result = [NSMutableArray array];
    
    for(id proto in [RegisteredInterceptors allKeys])
    {
        if([class conformsToProtocol:NSProtocolFromString(proto)])
        {
            [result addObject:[RegisteredInterceptors valueForKey:proto]];
        }
    }
    
    return result;
}

- (id) newInstanceOfProtocol: (Protocol *)proto
{
    id result = [self newInstanceOfName:NSStringFromProtocol(proto)];    
    [self satisfyImportsForObject:result];
    return result;
}

- (id) newInstanceOfClass: (Class)class
{
    id result = [self newInstanceOfName:NSStringFromClass(class)];
    [self satisfyImportsForObject:result];
    return result;
}

- (id) newInstanceOfName: (NSString *)name;
{
    InitializerBlock intializerBlock = [RegisteredClasses valueForKey:name];
    if(intializerBlock == nil)
    {
        NSLog(@"Class %@ was not registered with the container.", name);
        return nil;
    }
    
    id result = [[OCIOCDynamicProxy alloc] initWithBlock:intializerBlock];
    
    if(result == nil)
    {
        NSLog(@"Initializer block regiester for Class %@ returned nil", name);
        return nil;
    }
    
    [self addInterceptorsToProxy:result];
    return result;    
}

- (void) addInterceptorsToProxy: (id) proxy
{
    NSArray *interceptors = [self registeredInterceptorsForClass:[proxy InnerClass]];
    if(interceptors == nil)
    {
        return;
    }
    
    for(id interceptor in interceptors)
    {
        [proxy addInterceptor:interceptor];
    }
}

- (void) satisfyImportsForObject: (id)object
{
    if([object class] == [OCIOCDynamicProxy class])
    {
        object = [(OCIOCDynamicProxy *)object InnerObject];
    }
    
    NSMutableString *propertyTypeDisplayName = [NSMutableString string];
    
    NSDictionary *properties = [OCIOCPropertyUtils classProperties:[object class]];
    NSSet *importPropertyKeys = [properties keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop)
        {
            return [[(NSString *)key lowercaseString] hasPrefix:@"import"];
        }];
    
    for(id key in importPropertyKeys)
    {
        NSString *propertyDisplayName = [NSString stringWithFormat:@"%@.%@", [object class], key];
        InitializerBlock initializer = nil;
        
        NSDictionary *propertyAttrs = [properties valueForKey:key];
        Class class = (Class)[propertyAttrs valueForKey:PropertyType];
        NSArray *protocols = (NSArray *)[propertyAttrs valueForKey:PropertyProtocols];
        
        if(class == nil && protocols == nil)
        {
            NSLog(@"Cannot satisfy imports for property %@ becuase the type is 'id' with no protocol", propertyDisplayName);
            continue;
        }
        
        // check for registered type first
        if(class == nil)
        {
            [propertyTypeDisplayName appendString:@"id"];           
        }
        else
        {
            [propertyTypeDisplayName appendString:NSStringFromClass(class)];
            initializer = [RegisteredClasses valueForKey:NSStringFromClass(class)];
        }
        
        if(initializer == nil)
        {
            // check for a registered protocol
            if(protocols == nil || [protocols count] == 0)
            {
                NSLog(@"Cannot satisfy import for %@, becuase the type %@ was not registered", propertyDisplayName, NSStringFromClass(class));
                continue;
            }
            if([protocols count] > 1)
            {
                NSLog(@"Cannot satisfy import for %@, because it specifies more than one protocol", propertyDisplayName);
                continue;
            }
            NSString *protoName = NSStringFromProtocol((Protocol *)[protocols objectAtIndex:0]);
            [propertyTypeDisplayName appendFormat:@"<%@>", protoName];
            initializer = [RegisteredClasses valueForKey:protoName];
        }
        if(initializer == nil)
        {
            NSLog(@"Unable to satisfy dependencies for %@ because the type %@ was not registered", propertyDisplayName, propertyTypeDisplayName);
            continue;
        }
        else
        {
            // finally, satisfy the depedency.
            // TODO: Add support for custom setter methods
            id value = initializer();
            SEL selector = NSSelectorFromString([self defaultSetterForProperty: key]);
            [object performSelector:selector withObject:value];
        }
    }
}

- (NSString *) defaultSetterForProperty: (NSString *)property
{
    NSString *firstLetter = [property substringWithRange:NSMakeRange(0,1)];
    return [NSString stringWithFormat:@"set%@%@:", [firstLetter uppercaseString], [property substringFromIndex:1]];
}

@end