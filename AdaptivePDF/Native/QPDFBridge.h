#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Merge standard annotation objects into the original object graph. Page
/// contents, fonts (including ToUnicode), images, outlines and links stay original.
FOUNDATION_EXPORT NSData * _Nullable APDFWritePreservingContent(
    NSData *source, NSData *annotationPDF, NSArray *pagePlans, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL APDFVerifyOriginalContent(
    NSData *source, NSData *candidate, NSError * _Nullable * _Nullable error);
/// In-memory display copy only. Original image streams are never recolored.
/// Unsupported pages are left in original colors and listed in the result.
FOUNDATION_EXPORT NSDictionary * _Nullable APDFCreateImagePreservingDisplay(
    NSData *source, NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
