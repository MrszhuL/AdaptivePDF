#import "QPDFBridge.h"
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/Pl_Buffer.hh>
#include <algorithm>
#include <cmath>
#include <sstream>
#include <stdexcept>
#include <set>

namespace {
using Object = QPDFObjectHandle;
using Token = QPDFTokenizer::Token;
struct Colors { std::string fill = "/DeviceGray", stroke = "/DeviceGray"; };

// Lexical tokens keep strings, comments and binary inline images out of the
// operator parser. This filter is never attached to the original live PDF.
class DarkTokens final : public Object::TokenFilter {
    QPDF& pdf;
    Object resources;
    Colors colors;
    std::vector<Colors> stack;
    std::vector<Token> operands;
    std::string pending;
    bool inlineImage = false, inlineMaskKey = false, path = false;
    int depth;
    size_t& budget;
    std::set<QPDFObjGen> ancestors;
    std::string colorSpace(std::string name) {
        if (name == "/DeviceGray" || name == "/DeviceRGB" || name == "/DeviceCMYK") return name;
        auto dictionary = resources.getKey("/ColorSpace");
        if (!dictionary.isDictionary()) throw std::runtime_error("Missing drawing color space");
        auto value = dictionary.getKey(name);
        if (value.isName()) {
            name = value.getName();
            if (name == "/DeviceGray" || name == "/DeviceRGB" || name == "/DeviceCMYK") return name;
        } else if (value.isArray() && value.getArrayNItems() >= 2) {
            auto kind = value.getArrayItem(0);
            if (kind.isNameAndEquals("/CalGray")) return "/DeviceGray";
            if (kind.isNameAndEquals("/CalRGB")) return "/DeviceRGB";
            if (kind.isNameAndEquals("/ICCBased")) {
                auto profile = value.getArrayItem(1);
                if (profile.isStream()) {
                    auto count = profile.getDict().getKey("/N");
                    if (count.isInteger()) {
                        if (count.getIntValue() == 1) return "/DeviceGray";
                        if (count.getIntValue() == 3) return "/DeviceRGB";
                        if (count.getIntValue() == 4) return "/DeviceCMYK";
                    }
                }
            }
        }
        throw std::runtime_error("Special drawing color space: retain original page");
    }
    std::string neutral(std::string const& op) {
        std::vector<double> values;
        for (auto const& t : operands) {
            if (t.getType() != QPDFTokenizer::tt_integer && t.getType() != QPDFTokenizer::tt_real) return "";
            double x = std::stod(t.getValue());
            if (!std::isfinite(x) || x < 0 || x > 1) return "";
            values.push_back(x);
        }
        bool stroke = op == "G" || op == "RG" || op == "K" || op == "SC" || op == "SCN";
        std::string space = stroke ? colors.stroke : colors.fill;
        if (op == "g" || op == "G") space = "/DeviceGray";
        if (op == "rg" || op == "RG") space = "/DeviceRGB";
        if (op == "k" || op == "K") space = "/DeviceCMYK";
        (stroke ? colors.stroke : colors.fill) = space;
        double r, g, b;
        if (space == "/DeviceGray" && values.size() == 1) r = g = b = values[0];
        else if (space == "/DeviceRGB" && values.size() == 3) { r = values[0]; g = values[1]; b = values[2]; }
        else if (space == "/DeviceCMYK" && values.size() == 4) {
            r = (1-values[0])*(1-values[3]); g = (1-values[1])*(1-values[3]); b = (1-values[2])*(1-values[3]);
        } else throw std::runtime_error("Unsupported drawing color space");
        if (std::max({r,g,b}) - std::min({r,g,b}) > 0.025) return "";
        double value = 0.90 - (0.90 - 36.0/255.0) * (r+g+b)/3;
        // Keep the original color space active for subsequent SC/SCN operators.
        std::ostringstream out;
        bool generic = op == "sc" || op == "SC" || op == "scn" || op == "SCN";
        if (space == "/DeviceGray") out << value << " " << (generic ? op : stroke ? "G" : "g") << "\n";
        else if (space == "/DeviceRGB") out << value << " " << value << " " << value << " " << (generic ? op : stroke ? "RG" : "rg") << "\n";
        else out << "0 0 0 " << 1-value << " " << (generic ? op : stroke ? "K" : "k") << "\n";
        return out.str();
    }
    void backdrop() {
        if (path) throw std::runtime_error("Image inside an unfinished drawing path");
        write("q 1 1 1 rg 0 0 1 1 re f Q\n");
    }
    void checkGraphicsState(Object state) {
        if (!state.isDictionary()) throw std::runtime_error("Missing graphics state");
        for (auto key : {"/ca", "/CA"}) {
            auto a = state.getKey(key);
            if (!a.isNull() && (!a.isNumber() || a.getNumericValue() != 1))
                throw std::runtime_error("Transparent graphics state: retain original page");
        }
        for (auto key : {"/SMask", "/BM", "/TR", "/TR2"}) {
            auto value = state.getKey(key);
            if (!value.isNull() && !value.isNameAndEquals("/None") &&
                !value.isNameAndEquals("/Normal") && !value.isNameAndEquals("/Identity") &&
                !value.isNameAndEquals("/Default"))
                throw std::runtime_error("Complex compositing: retain original page");
        }
    }
    std::string drawObject() {
        if (operands.size() != 1 || operands[0].getType() != QPDFTokenizer::tt_name)
            throw std::runtime_error("Invalid XObject invocation");
        auto objects = resources.getKey("/XObject");
        auto object = objects.getKey(operands[0].getValue());
        if (!object.isStream()) throw std::runtime_error("Missing XObject");
        auto dict = object.getDict();
        if (dict.getKey("/Subtype").isNameAndEquals("/Image")) {
            if (dict.getKey("/ImageMask").isBool() && dict.getKey("/ImageMask").getBoolValue())
                throw std::runtime_error("Stencil image: retain original page");
            // An opaque white backing preserves transparent image edge colors
            // on ordinary white-paper PDFs, including image /SMask alpha.
            backdrop();
        } else if (dict.getKey("/Subtype").isNameAndEquals("/Form")) {
            auto nested = ancestors;
            if (depth >= 24 || !nested.insert(object.getObjGen()).second)
                throw std::runtime_error("Recursive form graph");
            auto formResources = dict.getKey("/Resources");
            if (formResources.isNull()) formResources = resources;
            DarkTokens filter(pdf, formResources, colors, depth+1, budget, nested);
            Pl_Buffer buffer("dark form");
            object.filterAsContents(&filter, &buffer);
            auto bytes = buffer.getBufferSharedPointer();
            auto clone = object.copyStream();
            clone.replaceStreamData(std::string((char const*)bytes->getBuffer(), bytes->getSize()), Object::newNull(), Object::newNull());
            clone.getDict().replaceKey("/Resources", filter.getResources());
            // Keep original aliases as well; all image and font objects remain
            // unmodified. A fresh alias handles forms invoked with new state.
            std::string alias = "/APDFDarkForm" + std::to_string(++budget);
            while (objects.hasKey(alias)) alias += "x";
            objects.replaceKey(alias, clone);
            resources.replaceKey("/XObject", objects);
            return alias + " Do\n";
        } else throw std::runtime_error("Unsupported XObject subtype");
        return "";
    }
  public:
    DarkTokens(QPDF& pdf, Object resource, Colors initial, int depth, size_t& budget,
               std::set<QPDFObjGen> ancestors = {}) : pdf(pdf), colors(initial), depth(depth), budget(budget), ancestors(ancestors) {
        resources = resource.isDictionary() ? resource.shallowCopy() : Object::newDictionary();
        auto objects = resources.getKey("/XObject");
        if (objects.isDictionary()) resources.replaceKey("/XObject", objects.shallowCopy());
    }
    Object getResources() { return resources; }
    void handleToken(Token const& token) override {
        if (++budget > 8000000) throw std::runtime_error("Display transformation exceeds token budget");
        auto type = token.getType();
        if (type == QPDFTokenizer::tt_bad) throw std::runtime_error("Malformed content token");
        if (type == QPDFTokenizer::tt_eof) { write(pending); pending.clear(); return; }
        if (inlineImage) {
            if (type == QPDFTokenizer::tt_name)
                inlineMaskKey = token.getValue() == "/IM" || token.getValue() == "/ImageMask";
            else if (inlineMaskKey && type == QPDFTokenizer::tt_bool && token.getValue() == "true")
                throw std::runtime_error("Inline stencil image: retain original page");
            writeToken(token);
            if (token.isWord("EI")) inlineImage = false;
            return;
        }
        if (type == QPDFTokenizer::tt_word) {
            auto op = token.getValue();
            std::string replacement;
            if (op == "g" || op == "G" || op == "rg" || op == "RG" || op == "k" || op == "K" ||
                op == "sc" || op == "SC" || op == "scn" || op == "SCN") replacement = neutral(op);
            else if (op == "cs" || op == "CS") {
                if (operands.size() != 1) throw std::runtime_error("Invalid color space operator");
                std::string name = colorSpace(operands[0].getValue());
                (op == "cs" ? colors.fill : colors.stroke) = name;
                // Changing a color space resets its initial color to black.
                std::string value = name == "/DeviceGray" ? "0.9" : name == "/DeviceRGB" ? "0.9 0.9 0.9" : "0 0 0 0.1";
                replacement = pending + " " + op + "\n" + value + (op == "cs" ? " sc\n" : " SC\n");
            } else if (op == "q") stack.push_back(colors);
            else if (op == "Q") {
                if (stack.empty()) throw std::runtime_error("Unbalanced graphics state");
                colors = stack.back(); stack.pop_back();
            } else if (op == "gs") {
                if (operands.size() != 1) throw std::runtime_error("Invalid graphics state operator");
                checkGraphicsState(resources.getKey("/ExtGState").getKey(operands[0].getValue()));
            } else if (op == "Do") replacement = drawObject();
            else if (op == "BI") { backdrop(); inlineImage = true; }
            if (op == "m" || op == "l" || op == "c" || op == "v" || op == "y" || op == "re") path = true;
            if (op == "S" || op == "s" || op == "f" || op == "F" || op == "f*" || op == "B" ||
                op == "B*" || op == "b" || op == "b*" || op == "n") path = false;
            if (replacement.empty()) { write(pending); writeToken(token); }
            else write(replacement);
            write("\n"); pending.clear(); operands.clear();
        } else {
            pending += token.getRawValue();
            if (type != QPDFTokenizer::tt_space && type != QPDFTokenizer::tt_comment) operands.push_back(token);
        }
    }
};
}

NSDictionary *APDFCreateImagePreservingDisplay(NSData *data, NSError **error) {
    try {
        QPDF pdf;
        pdf.setSuppressWarnings(true);
        pdf.processMemoryFile("display-source.pdf", (char const*)data.bytes, data.length);
        if (pdf.isEncrypted()) throw std::runtime_error("Encrypted PDF: image-preserving dark display unavailable");
        auto pages = QPDFPageDocumentHelper(pdf).getAllPages();
        NSMutableArray *supported = [NSMutableArray array], *reasons = [NSMutableArray array];
        size_t budget = 0;
        for (auto& page : pages) {
            bool success = false;
            NSString *reason = @"";
            try {
                DarkTokens filter(pdf, page.getAttribute("/Resources", false), Colors{}, 0, budget);
                Pl_Buffer stream("dark page");
                page.filterContents(&filter, &stream);
                auto buffer = stream.getBufferSharedPointer();
                auto box = page.getMediaBox();
                double x = box.getArrayItem(0).getNumericValue(), y = box.getArrayItem(1).getNumericValue();
                double w = box.getArrayItem(2).getNumericValue()-x, h = box.getArrayItem(3).getNumericValue()-y;
                std::ostringstream prefix;
                prefix << "q 0.14117647 g " << x << " " << y << " " << w << " " << h << " re f Q\n0.9 g 0.9 G\n";
                auto content = Object::newStream(&pdf, prefix.str() + std::string((char const*)buffer->getBuffer(), buffer->getSize()));
                auto dict = page.getObjectHandle();
                dict.replaceKey("/Contents", content);
                dict.replaceKey("/Resources", filter.getResources());
                success = true;
            } catch (std::exception const& failure) { reason = [NSString stringWithUTF8String:failure.what()] ?: @"Unsupported page"; }
            // Annotations remain live in the original PDFView document.
            page.getObjectHandle().removeKey("/Annots");
            [supported addObject:@(success)]; [reasons addObject:reason];
        }
        // Copy encoded image bytes without recompression, including their masks,
        // profiles, decode arrays and original interpolation settings.
        for (auto object : pdf.getAllObjects())
            if (object.isStream() && object.getDict().getKey("/Subtype").isNameAndEquals("/Image")) object.setFilterOnWrite(false);
        QPDFWriter writer(pdf);
        writer.setOutputMemory(); writer.setStreamDataMode(qpdf_s_preserve); writer.write();
        if (pdf.anyWarnings()) throw std::runtime_error("PDF warnings: retain original display");
        auto buffer = writer.getBufferSharedPointer();
        return @{@"data": [NSData dataWithBytes:buffer->getBuffer() length:buffer->getSize()],
                 @"supported": supported, @"reasons": reasons};
    } catch (std::exception const& failure) {
        if (error) *error = [NSError errorWithDomain:@"AdaptivePDF.ImagePreservingDisplay" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()] ?: @"Display preparation failed"}];
        return nil;
    }
}
