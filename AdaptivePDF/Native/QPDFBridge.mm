#import "QPDFBridge.h"
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFAcroFormDocumentHelper.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <cmath>
#include <algorithm>
#include <map>
#include <stdexcept>
#include <vector>
#include <set>
#include <cstring>

namespace {
using Object = QPDFObjectHandle;
long number(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    if (![value isKindOfClass:NSNumber.class]) throw std::runtime_error("Invalid annotation merge plan");
    return [value longValue];
}
void validate(Object annotation, NSDictionary *expected) {
    if (!annotation.isDictionary()) throw std::runtime_error("Annotation is not a dictionary");
    NSString *type = expected[@"type"];
    if (type.length && annotation.getKey("/Subtype").getName() != "/" + std::string(type.UTF8String))
        throw std::runtime_error("Annotation subtype order differs between PDFKit and the source PDF");
    NSArray *bounds = expected[@"bounds"];
    auto rect = annotation.getKey("/Rect");
    if (bounds.count != 4 || !rect.isArray() || rect.getArrayNItems() != 4)
        throw std::runtime_error("Annotation bounds cannot be matched safely");
    double x1 = rect.getArrayItem(0).getNumericValue(), y1 = rect.getArrayItem(1).getNumericValue();
    double x2 = rect.getArrayItem(2).getNumericValue(), y2 = rect.getArrayItem(3).getNumericValue();
    double values[] = {std::min(x1,x2), std::min(y1,y2), std::max(x1,x2), std::max(y1,y2)};
    if (annotation.getKey("/Subtype").isNameAndEquals("/Text")) {
        // PDFKit normalizes sticky-note icons to 24pt, anchored at the top left,
        // even when the source /Rect is 20pt. Match anchor + original contents.
        auto contents = annotation.getKey("/Contents");
        id wanted = expected[@"contents"];
        bool equalText = wanted == NSNull.null ? contents.isNull() :
            (contents.isString() && contents.getUTF8Value() == std::string([wanted UTF8String]));
        if (!equalText || std::abs(values[0] - [bounds[0] doubleValue]) > 0.01 ||
            std::abs(values[3] - [bounds[3] doubleValue]) > 0.01)
            throw std::runtime_error("Sticky note anchor or contents differ from the source");
        return;
    }
    for (int i = 0; i != 4; ++i) {
        double wanted = [bounds[i] doubleValue];
        if (!std::isfinite(wanted) || !std::isfinite(values[i]) || std::abs(wanted - values[i]) > 0.01)
            throw std::runtime_error("Annotation coordinates differ from the source PDF");
    }
}
Object importObject(QPDF& source, QPDF& foreign, Object object) {
    if (!object.isIndirect()) object = foreign.makeIndirectObject(object);
    return source.copyForeignObject(object);
}
bool hasSignatures(QPDF& pdf, QPDFAcroFormDocumentHelper& forms) {
    auto permissions = pdf.getRoot().getKey("/Perms");
    for (auto key : {"/DocMDP", "/UR", "/UR3"}) {
        if (!permissions.getKeyIfDict(key).isNull()) return true;
    }
    if (!forms.hasAcroForm()) return false;
    for (auto field : forms.getFormFields()) {
        if (field.getFieldType() == "/Sig" && !field.getValue().isNull()) return true;
    }
    return false;
}

void copyKey(QPDF& source, QPDF& edits, Object target, Object foreign, const char* key,
             bool clearAbsent = false) {
    auto value = foreign.getKey(key);
    if (!value.isNull()) target.replaceKey(key, importObject(source, edits, value));
    else if (clearAbsent) target.removeKey(key);
}
using Seen = std::set<std::pair<QPDFObjGen, QPDFObjGen>>;
bool sameContent(Object a, Object b, Seen& seen, int depth = 0) {
    if (depth > 256) throw std::runtime_error("PDF resource graph exceeds the verification depth limit");
    if (a.isIndirect() && b.isIndirect() && !seen.emplace(a.getObjGen(), b.getObjGen()).second) return true;
    if (a.isNumber() && b.isNumber()) return a.getNumericValue() == b.getNumericValue();
    if (a.getTypeCode() != b.getTypeCode()) return false;
    if (a.isNull()) return true;
    if (a.isBool()) return a.getBoolValue() == b.getBoolValue();
    if (a.isName()) return a.getName() == b.getName();
    if (a.isString()) return a.getStringValue() == b.getStringValue();
    if (a.isArray()) {
        if (a.getArrayNItems() != b.getArrayNItems()) return false;
        for (int i = 0; i != a.getArrayNItems(); ++i)
            if (!sameContent(a.getArrayItem(i), b.getArrayItem(i), seen, depth + 1)) return false;
        return true;
    }
    if (a.isStream()) {
        auto x = a.getRawStreamData(), y = b.getRawStreamData();
        if (x->getSize() != y->getSize() || std::memcmp(x->getBuffer(), y->getBuffer(), x->getSize()) != 0) return false;
        return sameContent(a.getDict(), b.getDict(), seen, depth + 1);
    }
    if (a.isDictionary()) {
        if (a.getKeys() != b.getKeys()) return false;
        for (auto const& key : a.getKeys())
            if (!sameContent(a.getKey(key), b.getKey(key), seen, depth + 1)) return false;
        return true;
    }
    return false;
}
void verifyPages(QPDF& original, QPDF& candidate) {
    auto pages = QPDFPageDocumentHelper(original).getAllPages();
    auto verifiedPages = QPDFPageDocumentHelper(candidate).getAllPages();
    if (verifiedPages.size() != pages.size()) throw std::runtime_error("Output page count changed");
    Seen seen;
    for (size_t i = 0; i != pages.size(); ++i) {
        if (!sameContent(pages[i].getObjectHandle().getKey("/Contents"),
                         verifiedPages[i].getObjectHandle().getKey("/Contents"), seen))
            throw std::runtime_error("A page content stream changed while saving annotations");
        for (auto key : {"/Resources", "/MediaBox", "/CropBox", "/Rotate", "/BleedBox", "/TrimBox", "/ArtBox"})
            if (!sameContent(pages[i].getAttribute(key, false), verifiedPages[i].getAttribute(key, false), seen))
                throw std::runtime_error("A page resource, font, image, or page box changed");
    }
}
}

BOOL APDFHasPDFSignatures(NSData *data, CGPDFDocumentRef document) {
    if (document) {
        auto catalog = CGPDFDocumentGetCatalog(document);
        CGPDFDictionaryRef form;
        CGPDFArrayRef fields;
        CGPDFObjectRef entry;
        bool hasFields = catalog && CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form) &&
            CGPDFDictionaryGetArray(form, "Fields", &fields) && CGPDFArrayGetCount(fields) > 0;
        if (catalog && !hasFields &&
            !CGPDFDictionaryGetObject(catalog, "Perms", &entry)) return NO;
    }
    try {
        QPDF pdf;
        pdf.setSuppressWarnings(true);
        pdf.processMemoryFile("signature-check.pdf", (const char *)data.bytes, data.length);
        QPDFAcroFormDocumentHelper forms(pdf);
        return hasSignatures(pdf, forms);
    } catch (std::exception const&) {
        // The writer will refuse to rewrite source data it cannot parse.
        return NO;
    }
}

BOOL APDFVerifyOriginalContent(NSData *sourceData, NSData *candidateData, NSError **error) {
    try {
        QPDF original, candidate;
        original.setSuppressWarnings(true); candidate.setSuppressWarnings(true);
        original.processMemoryFile("original.pdf", (const char *)sourceData.bytes, sourceData.length);
        candidate.processMemoryFile("candidate.pdf", (const char *)candidateData.bytes, candidateData.length);
        verifyPages(original, candidate);
        if (original.anyWarnings() || candidate.anyWarnings()) throw std::runtime_error("PDF structure warnings prevent verification");
        return YES;
    } catch (std::exception const& exception) {
        if (error) *error = [NSError errorWithDomain:@"AdaptivePDF.ContentVerification" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithUTF8String:exception.what()] ?: @"PDF content verification failed"
        }];
        return NO;
    }
}

NSData *APDFWritePreservingContent(NSData *data, NSData *annotationData, NSArray *plans, NSError **error) {
    try {
        QPDF source, edits;
        source.setSuppressWarnings(true);
        source.processMemoryFile("original.pdf", (const char *)data.bytes, data.length);
        if (source.isEncrypted()) throw std::runtime_error("Encrypted PDFs are read-only");
        QPDFAcroFormDocumentHelper sourceForms(source);
        if (hasSignatures(source, sourceForms))
            throw std::runtime_error("A full rewrite would invalidate existing digital signatures");
        auto pages = QPDFPageDocumentHelper(source).getAllPages();
        if (pages.size() != plans.count) throw std::runtime_error("Original page count does not match the document");
        std::vector<QPDFPageObjectHelper> editPages;
        if (annotationData.length) {
            edits.setSuppressWarnings(true);
            edits.processMemoryFile("annotations.pdf", (const char *)annotationData.bytes, annotationData.length);
            editPages = QPDFPageDocumentHelper(edits).getAllPages();
        }
        QPDFAcroFormDocumentHelper editForms(edits);
        std::vector<std::vector<Object>> originals(pages.size());
        for (size_t page = 0; page != pages.size(); ++page) {
            auto array = pages[page].getObjectHandle().getKey("/Annots");
            if (array.isArray()) {
                for (int i = 0; i != array.getArrayNItems(); ++i) originals[page].push_back(array.getArrayItem(i));
            } else if (!array.isNull()) throw std::runtime_error("Invalid original annotation array");
            id plan = plans[page];
            if (plan == NSNull.null) continue;
            NSArray *expected = plan[@"original"];
            if (originals[page].size() != expected.count)
                throw std::runtime_error("PDFKit and the source disagree on the annotation count");
            for (size_t i = 0; i != originals[page].size(); ++i) validate(originals[page][i], expected[i]);
        }

        // Remove page references before importing, so no rewritten blank page or
        // font tree can become reachable from an imported annotation's /P key.
        for (auto& page : editPages) {
            auto array = page.getObjectHandle().getKey("/Annots");
            if (!array.isArray()) continue;
            for (int i = 0; i != array.getArrayNItems(); ++i) {
                auto annotation = array.getArrayItem(i);
                annotation.removeKey("/P");
                auto popup = annotation.getKey("/Popup");
                if (popup.isDictionary()) popup.removeKey("/P");
            }
        }
        std::map<QPDFObjGen, Object> replacements;
        std::map<QPDFObjGen, QPDFFormFieldObjectHelper> changedButtons;
        std::vector<std::vector<Object>> results(pages.size());
        for (size_t page = 0; page != pages.size(); ++page) {
            id plan = plans[page];
            if (plan == NSNull.null) {
                results[page] = originals[page];
                for (auto object : originals[page]) if (object.isIndirect()) replacements[object.getObjGen()] = object;
                continue;
            }
            for (NSDictionary *item in plan[@"current"]) {
                long oldPage = number(item, @"originalPage"), oldIndex = number(item, @"originalIndex");
                Object prior = Object::newNull();
                if (oldIndex >= 0) {
                    if (oldPage < 0 || oldPage >= (long)originals.size() || oldIndex >= (long)originals[oldPage].size())
                        throw std::runtime_error("Original annotation reference is out of range");
                    prior = originals[oldPage][oldIndex];
                }
                Object result = prior;
                if (item[@"shadowIndex"]) {
                    long shadowPage = number(item, @"shadowPage"), shadowIndex = number(item, @"shadowIndex");
                    if (shadowPage < 0 || shadowPage >= (long)editPages.size()) throw std::runtime_error("Missing annotation-only page");
                    auto array = editPages[shadowPage].getObjectHandle().getKey("/Annots");
                    if (!array.isArray() || shadowIndex < 0 || shadowIndex >= array.getArrayNItems())
                        throw std::runtime_error("Missing annotation-only object");
                    auto foreign = array.getArrayItem((int)shadowIndex);
                    validate(foreign, item);
                    if (prior.isDictionary() && prior.getKey("/Subtype").isNameAndEquals("/Widget")) {
                        auto field = sourceForms.getFieldForAnnotation(QPDFAnnotationObjectHelper(prior));
                        auto parent = prior.getKey("/Parent");
                        // A separate unnamed widget is only the appearance of
                        // its immediate field. qpdf may expose it as a node in
                        // the field tree, but the field value belongs to /Parent.
                        if (!prior.hasKey("/T") && parent.isDictionary()) field = QPDFFormFieldObjectHelper(parent);
                        auto terminal = field.getObjectHandle();
                        if (!terminal.isDictionary())
                            throw std::runtime_error("Edited widget has no terminal AcroForm field");
                        for (auto key : {"/AP", "/M"}) copyKey(source, edits, prior, foreign, key);
                        auto appearanceState = foreign.getKey("/AS");
                        if (appearanceState.isName()) prior.replaceKey("/AS", Object::newName(appearanceState.getName()));
                        if (!terminal.isSameObjectAs(prior)) {
                            prior.removeKey("/V");
                            prior.removeKey("/I");
                        }
                        if (field.isCheckbox() || field.isRadioButton()) {
                            if (![item[@"buttonOn"] boolValue]) {
                                prior.replaceKey("/AS", Object::newName("/Off"));
                            } else {
                                auto state = foreign.getKey("/AS");
                                if (!state.isName() || state.isNameAndEquals("/Off")) {
                                    auto normal = prior.getKeyIfDict("/AP").getKeyIfDict("/N");
                                    auto value = foreign.getKey("/V");
                                    if (value.isName() && !value.isNameAndEquals("/Off") &&
                                        normal.isDictionary() && normal.hasKey(value.getName())) {
                                        state = Object::newName(value.getName());
                                    } else if (normal.isDictionary()) {
                                        for (auto const& key : normal.getKeys()) {
                                            if (key != "/Off") { state = Object::newName(key); break; }
                                        }
                                    }
                                    if (!state.isName() || state.isNameAndEquals("/Off"))
                                        throw std::runtime_error("Cannot determine a checked widget's appearance state");
                                    prior.replaceKey("/AS", state);
                                }
                            }
                            changedButtons.emplace(terminal.getObjGen(), field);
                        } else if (field.isText() || field.isChoice()) {
                            auto exportedField = editForms.getFieldForAnnotation(QPDFAnnotationObjectHelper(foreign));
                            auto value = foreign.getKey("/V");
                            if (value.isNull() && !exportedField.getObjectHandle().isNull()) value = exportedField.getValue();
                            if (!value.isNull()) field.setV(importObject(source, edits, value), false);
                            else {
                                id text = item[@"fieldText"];
                                field.setV([text isKindOfClass:NSString.class] ?
                                    std::string([text UTF8String]) : std::string(), false);
                            }
                            if (field.isChoice()) {
                                auto choices = exportedField.getObjectHandle();
                                if (!choices.isDictionary() || !choices.hasKey("/I")) choices = foreign;
                                copyKey(source, edits, terminal, choices, "/I", true);
                            }
                        }
                    } else if (prior.isDictionary()) {
                        // Other annotations, the structure tree and reply threads can all
                        // refer to this object. Merge only the properties our editor changes.
                        bool contents = [item[@"contentsChanged"] boolValue];
                        bool color = [item[@"colorChanged"] boolValue];
                        bool bounds = ![item[@"keepOriginalBounds"] boolValue];
                        bool quads = [item[@"quadsChanged"] boolValue];
                        if (contents) copyKey(source, edits, prior, foreign, "/Contents", true);
                        if (color) {
                            copyKey(source, edits, prior, foreign, "/C", true);
                            copyKey(source, edits, prior, foreign, "/CA");
                        }
                        if (bounds) copyKey(source, edits, prior, foreign, "/Rect");
                        if (quads) copyKey(source, edits, prior, foreign, "/QuadPoints", true);
                        if (color || bounds || quads || (contents && prior.getKey("/Subtype").isNameAndEquals("/FreeText")))
                            copyKey(source, edits, prior, foreign, "/AP", true);
                        copyKey(source, edits, prior, foreign, "/M");
                    } else {
                        result = importObject(source, edits, foreign);
                    }
                    result.replaceKey("/P", pages[page].getObjectHandle());
                    auto popup = result.getKey("/Popup");
                    if (popup.isDictionary()) popup.replaceKey("/P", pages[page].getObjectHandle());
                }
                if (result.isNull()) throw std::runtime_error("Annotation has neither an original nor an exported object");
                if (prior.isIndirect()) replacements[prior.getObjGen()] = result;
                results[page].push_back(result);
            }
        }
        for (auto& entry : changedButtons) {
            auto& field = entry.second;
            // Compute the group value after all of its widgets have been merged.
            auto selected = Object::newName("/Off");
            auto terminal = field.getObjectHandle();
            auto widgets = terminal.getKey("/Kids");
            auto candidates = widgets.isArray() ? widgets.getArrayAsVector() : std::vector<Object>{terminal};
            for (auto candidate : candidates) {
                auto state = candidate.getKeyIfDict("/AS");
                if (state.isName() && !state.isNameAndEquals("/Off")) {
                    selected = state;
                    break;
                }
            }
            field.setFieldAttribute("/V", selected);
        }
        for (size_t page = 0; page != pages.size(); ++page) {
            if (plans[page] == NSNull.null) continue; // reply links are on the same page
            std::vector<Object> filtered;
            for (auto object : results[page]) {
                auto replyTo = object.getKey("/IRT");
                if (replyTo.isIndirect() && replacements.find(replyTo.getObjGen()) == replacements.end()) {
                    object.removeKey("/IRT");
                    object.removeKey("/RT");
                }
                if (object.getKey("/Subtype").isNameAndEquals("/Popup")) {
                    auto parent = object.getKey("/Parent");
                    if (parent.isIndirect()) {
                        auto found = replacements.find(parent.getObjGen());
                        if (found == replacements.end()) continue; // deleted review parent
                        auto newPopup = found->second.getKey("/Popup");
                        if (newPopup.isDictionary()) object = newPopup;
                        object.replaceKey("/Parent", found->second);
                    }
                }
                filtered.push_back(object);
            }
            auto dictionary = pages[page].getObjectHandle();
            if (filtered.empty()) dictionary.removeKey("/Annots");
            else dictionary.replaceKey("/Annots", Object::newArray(filtered));
        }
        QPDFWriter writer(source);
        writer.setOutputMemory();
        writer.setStreamDataMode(qpdf_s_preserve);
        writer.setObjectStreamMode(qpdf_o_preserve);
        writer.write();
        auto buffer = writer.getBufferSharedPointer();
        // Reparse the actual output and compare every page's content and resource
        // graph, including the exact encoded font, ToUnicode and image streams.
        // Object numbers and dictionary key ordering may legitimately change.
        QPDF verified;
        verified.setSuppressWarnings(true);
        verified.processMemoryFile("verified.pdf", (const char *)buffer->getBuffer(), buffer->getSize());
        verifyPages(source, verified);
        if (source.anyWarnings() || verified.anyWarnings() || (annotationData.length && edits.anyWarnings()))
            throw std::runtime_error("PDF structure warnings prevent a verified save");
        return [[NSData alloc] initWithBytesNoCopy:buffer->getBuffer() length:buffer->getSize()
            deallocator:^(void *, NSUInteger) { (void)buffer; }];
    } catch (std::exception const& exception) {
        if (error) {
            NSString *detail = [NSString stringWithUTF8String:exception.what()] ?: @"Unknown PDF preservation error";
            *error = [NSError errorWithDomain:@"AdaptivePDF.Preservation" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"无法安全合并此 PDF 的批注，已中止写入。原文件未被覆盖。",
                NSLocalizedFailureReasonErrorKey: detail
            }];
        }
        return nil;
    }
}
