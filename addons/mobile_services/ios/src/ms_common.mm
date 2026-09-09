/**************************************************************************/
/*  ms_common.mm                                                          */
/**************************************************************************/

#import "ms_common.h"

String ms_json_from_dictionary(NSDictionary *dictionary) {
	if (dictionary == nil) {
		return String("{}");
	}
	// isValidJSONObject first: NSJSONSerialization RAISES rather than returning
	// an error for an unserialisable object, and an ObjC exception crossing into
	// C++ here would take the app down for the sake of a log line.
	if (![NSJSONSerialization isValidJSONObject:dictionary]) {
		return String("{}");
	}
	NSError *error = nil;
	NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
	if (data == nil || error != nil) {
		return String("{}");
	}
	NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return ms_str(text);
}

String ms_json_from_array(NSArray *array) {
	if (array == nil || ![NSJSONSerialization isValidJSONObject:array]) {
		return String("[]");
	}
	NSError *error = nil;
	NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:&error];
	if (data == nil || error != nil) {
		return String("[]");
	}
	NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return ms_str(text);
}

NSDictionary *ms_dictionary_from_json(const String &json) {
	NSString *text = ms_ns(json);
	NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
	if (data == nil) {
		return @{};
	}
	NSError *error = nil;
	id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
	if (error != nil || ![parsed isKindOfClass:[NSDictionary class]]) {
		return @{};
	}
	return (NSDictionary *)parsed;
}

NSString *ms_ns(const String &value) {
	NSString *text = [NSString stringWithUTF8String:value.utf8().get_data()];
	return text == nil ? @"" : text;
}

String ms_str(NSString *value) {
	if (value == nil) {
		return String();
	}
	return String::utf8([value UTF8String]);
}
