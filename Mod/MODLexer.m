//
//  MODLexer.m
//  Mod
//
//  Created by Jonas Budelmann on 15/09/13.
//  Copyright (c) 2013 cloudling. All rights reserved.
//

#import "MODLexer.h"
#import "NSRegularExpression+MODAdditions.h"
#import "UIColor+MODAdditions.h"

@interface MODLexer ()

@property (nonatomic, strong) NSMutableString *str;
@property (nonatomic, strong) NSMutableArray *stash;
@property (nonatomic, strong) NSMutableArray *indentStack;
@property (nonatomic, strong) MODToken *previous;
@property (nonatomic, strong) NSDictionary *regexCache;

@end

@implementation MODLexer

- (id)initWithString:(NSString *)str {
    self = [super init];
    if (!self) return nil;

    self.str = [str mutableCopy];
    self.stash = NSMutableArray.new;
    self.indentStack = NSMutableArray.new;

    // replace carriage returns (\r\n | \r) with newlines
    [MODRegex(@"\\r\\n?") mod_replaceMatchesInString:self.str withTemplate:@"\n"];
    
    // trim whitespace & newlines from end of string
    [MODRegex(@"\\s+$") mod_replaceMatchesInString:self.str withTemplate:@"\n"];

    NSString *units = [@[@"pt", @"px"] componentsJoinedByString:@"|"];

    // cache regex's
    self.regexCache = @{

        // 1 of `;` followed by 0-* of whitespace
        @(MODTokenTypeSemiColon) : @[ MODRegex(@"^;[ \\t]*") ],

        // 1 of `{` or `}`
        @(MODTokenTypeBrace)     : @[ MODRegex(@"^([{}])") ],

        //#rrggbbaa | #rrggbb | #rgb
        @(MODTokenTypeColor)     : @[ MODRegex(@"^#([a-fA-F0-9]{8})[ \\t]*"),
                                      MODRegex(@"^#([a-fA-F0-9]{6})[ \\t]*"),
                                      MODRegex(@"^#([a-fA-F0-9]{3})[ \\t]*") ],

        // string enclosed in single or double quotes
        @(MODTokenTypeString)    : @[ MODRegex(@"^(\"[^\"]*\"|'[^']*')[ \t]*") ],

        // decimal/integer number with optional (px, pt) suffix
        @(MODTokenTypeUnit)      : @[ MODRegex(@"^(-)?(\\d+\\.\\d+|\\d+|\\.\\d+)(%@)?[ \\t]*", units) ],

        // true | false | YES | NO
        @(MODTokenTypeBoolean)   : @[ MODRegex(@"^(true|false|YES|NO)\\b([ \\t]*)") ],

        // optional `@` | `-` then at least one `_a-zA-Z$` following by any alphanumber or `-` or `$`
        @(MODTokenTypeRef)       : @[ MODRegex(@"^(@)?(-*[_a-zA-Z$][-\\w\\d$]*)") ],

        // 1-* of whitespace
        @(MODTokenTypeSpace)     : @[ MODRegex(@"^([ \\t]+)") ],

        // any character except `\n` | `{` | `,` and stop if encounter `//` unless its inbetween `[ ]`
        @(MODTokenTypeSelector)  : @[ MODRegex(@"^.*?(?=\\/\\/(?![^\\[]*\\])|[,\\n{])") ]
    };

    return self;
}


- (MODToken *)peekToken {
    return [self lookahead:1];
}

- (MODToken *)nextToken {
    MODToken *token = self.popToken ?: self.advanceToken;
    self.previous = token;
    return token;
}

#pragma mark - private

- (MODToken *)lookahead:(NSUInteger)n {
    NSInteger fetch = n - self.stash.count;
    while (fetch-- > 0) {
        MODToken *token = self.advanceToken;
        NSAssert(token, @"Could not parse token for string %@", self.str);
        [self.stash addObject:token];
    }
    return self.stash[--n];
}

- (void)skip:(NSUInteger)n {
    [self.str deleteCharactersInRange:NSMakeRange(0, n)];
}

- (MODToken *)advanceToken {
    // TODO optimise
    // this could possibly be faster using simple string scanning (NSScanner), instead of regex
    // however all these regexs are anchored to start of string so should be fairly quick
    return self.eos
        ?: self.seperator
        ?: self.comment
        ?: self.newline
        ?: self.brace
        ?: self.color
        ?: self.string
        ?: self.unit
        ?: self.boolean
        ?: self.ref
        ?: self.space
        ?: self.selector;
}

- (MODToken *)popToken {
    // Return the next stashed token and remove it from stash.
    if (self.stash.count) {
        MODToken *token = self.stash[0];
        [self.stash removeObjectAtIndex:0];
        return token;
    }
    return nil;
}

#pragma mark - tokens

- (MODToken *)eos {
    // EOS | trailing outdents.
    if (self.str.length) return nil;
    if (self.indentStack.count) {
        [self.indentStack removeObjectAtIndex:0];
        return [[MODToken alloc] initWithType:MODTokenTypeOutdent];
    } else {
        return [[MODToken alloc] initWithType:MODTokenTypeEOS];
    }
}

- (MODToken *)seperator {
    return [self testForTokenType:MODTokenTypeSemiColon transformValueBlock:nil];
}

- (MODToken *)comment {
    // Single line
    if ([self.str hasPrefix:@"//"]) {
        NSInteger nextLine = [self.str rangeOfString:@"\n"].location;
        if (nextLine == NSNotFound) {
            nextLine = self.str.length;
        }
        [self skip:nextLine];
        return self.advanceToken;
    }

    // Multi-line
    if ([self.str hasPrefix:@"/*"]) {
        NSInteger closeComment = [self.str rangeOfString:@"*/"].location;
        if (closeComment == NSNotFound) {
            closeComment = self.str.length;
        }
        [self skip:closeComment + 2];
        return self.advanceToken;
    }
    
    return nil;
}

- (MODToken *)newline {
    return nil;
}

- (MODToken *)brace {
    return [self testForTokenType:MODTokenTypeBrace transformValueBlock:^id(NSString *value, NSTextCheckingResult *match){
        return value;
    }];
}

- (MODToken *)color {
    return [self testForTokenType:MODTokenTypeColor transformValueBlock:^id(NSString *value, NSTextCheckingResult *match) {
        return [UIColor mod_colorWithHex:[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    }];
}

- (MODToken *)string {
    return [self testForTokenType:MODTokenTypeString transformValueBlock:^id(NSString *value, NSTextCheckingResult *match) {
        NSString *string = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return [string substringWithRange:NSMakeRange(1, string.length-2)];
    }];
}

- (MODToken *)unit {
    return [self testForTokenType:MODTokenTypeUnit transformValueBlock:^id(NSString *value, NSTextCheckingResult *match){
        //px,pt,% etc NSString *type = [self.str substringWithRange:[match rangeAtIndex:match.numberOfRanges-1]];
        NSString *string = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return @([string doubleValue]);
    }];
}

- (MODToken *)boolean {
    return [self testForTokenType:MODTokenTypeBoolean transformValueBlock:^id(NSString *value, NSTextCheckingResult *match) {
        return @([value hasPrefix:@"true"] || [value hasPrefix:@"YES"]);
    }];
}

- (MODToken *)ref {
    return [self testForTokenType:MODTokenTypeRef transformValueBlock:^id(NSString *value, NSTextCheckingResult *match) {
        return value;
    }];
}

- (MODToken *)space {
    return [self testForTokenType:MODTokenTypeSpace transformValueBlock:nil];
}

- (MODToken *)selector {
    return [self testForTokenType:MODTokenTypeSelector transformValueBlock:^id(NSString *value, NSTextCheckingResult *match) {
        return value;
    }];
}

#pragma mark - helpers

- (MODToken *)testForTokenType:(MODTokenType)tokenType transformValueBlock:(id(^)(NSString *value, NSTextCheckingResult *match))transformValueBlock {
    NSArray *regexes = self.regexCache[@(tokenType)];
    NSAssert(regexes, @"No cached regex for MODTokenType: %d", tokenType);
    for (NSRegularExpression *regex in regexes) {
        NSTextCheckingResult *match = [regex firstMatchInString:self.str options:0 range:NSMakeRange(0, self.str.length)];
        if (match) {
            MODToken *token = MODToken.new;
            token.type = tokenType;
            if (transformValueBlock) {
                token.value = transformValueBlock([self.str substringWithRange:match.range], match);
            }
            [self skip:match.range.length];
            return token;
        }
    }
    return nil;
}

@end
