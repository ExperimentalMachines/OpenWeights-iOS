import Foundation

// Android Llama32Prompt with verbatim assistant history. This bridge requests
// zero automatic BOS tokens, so its prompt includes exactly one textual BOS.
public enum CompiledLlama32Prompt {
    public static func today(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone=timeZone;formatter.dateFormat="dd MMM yyyy"
        return formatter.string(from:date)
    }
    public static func render(_ messages: [[String:String]], tools: [AgentToolDefinition] = [], date: String) throws -> String {
        let leading=messages.first?["role"] == "system" ? messages.first?["content"] ?? "" : ""
        var remaining=messages.first?["role"] == "system" ? Array(messages.dropFirst()) : messages
        var result="<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        if !tools.isEmpty { result += "Environment: ipython\n" }
        result += "Cutting Knowledge Date: December 2023\nToday Date: " + date + "\n\n" + trim(leading) + "<|eot_id|>"
        if !tools.isEmpty, !remaining.isEmpty {
            let first=remaining.removeFirst()
            result += "<|start_header_id|>user<|end_header_id|>\n\n"
            result += "Given the following functions, please respond with a JSON for a function call with its proper arguments that best answers the given prompt.\n\n"
            result += "Respond in the format {\"name\": function name, \"parameters\": dictionary of argument name and its value}.Do not use variables.\n\n"
            for tool in tools {
                guard let data=tool.parametersJSON.data(using:.utf8), (try? JSONSerialization.jsonObject(with:data)) is [String:Any] else {
                    throw ModelError.unsupported("A compiled-model tool requires a JSON object schema.")
                }
                let json="{\"type\": \"function\", \"function\": {\"name\": " + quote(tool.name)
                    + ", \"description\": " + quote(tool.description) + ", \"parameters\": " + canonical(tool.parametersJSON) + "}}"
                result += indent(json) + "\n\n"
            }
            result += trim(first["content"] ?? "") + "<|eot_id|>"
        }
        for message in remaining {
            let role=message["role"] ?? "user", text=message["content"] ?? ""
            guard ["system","user","assistant","tool"].contains(role) else { throw ModelError.unsupported("This compiled template cannot render that message role.") }
            let header=role == "tool" ? "ipython" : role
            result += "<|start_header_id|>" + header + "<|end_header_id|>\n\n"
            result += (role == "tool" ? quote(text) : role == "assistant" ? text : trim(text)) + "<|eot_id|>"
        }
        return result + "<|start_header_id|>assistant<|end_header_id|>\n\n"
    }
    private static func trim(_ text: String) -> String { text.trimmingCharacters(in:.whitespacesAndNewlines) }
    private static func quote(_ text: String) -> String {
        var result="\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 34:result += "\\\""
            case 92:result += "\\\\"
            case 10:result += "\\n"
            case 13:result += "\\r"
            case 9:result += "\\t"
            case 0..<32:result += String(format:"\\u%04x",scalar.value)
            default:result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    // Preserve key order, escapes and numeric spelling. Only schema whitespace
    // may change, matching Android's canonicalJson/reindentJson contract.
    private static func canonical(_ text: String) -> String {
        var result="", inString=false, escaped=false
        for character in text {
            if inString {
                result.append(character)
                if escaped { escaped=false } else if character == "\\" { escaped=true } else if character == "\"" { inString=false }
            } else if character == "\"" { result.append(character);inString=true }
            else if character == "," { result += ", " }
            else if character == ":" { result += ": " }
            else if ![" ","\n","\r","\t"].contains(character) { result.append(character) }
        }
        return result
    }
    private static func indent(_ text: String) -> String {
        let characters=Array(text);var result="", depth=0, inString=false, escaped=false, index=0
        while index<characters.count {
            let c=characters[index]
            if inString {
                result.append(c)
                if escaped { escaped=false } else if c == "\\" { escaped=true } else if c == "\"" { inString=false }
            } else if c == "\"" { result.append(c);inString=true }
            else if c == "{" || c == "[" {
                let closer: Character=c == "{" ? "}" : "]";var next=index+1
                while next<characters.count && characters[next] == " " { next+=1 }
                if next<characters.count && characters[next] == closer { result.append(c);result.append(closer);index=next }
                else { depth+=1;result.append(c);result += "\n" + String(repeating:" ",count:depth*4) }
            } else if c == "}" || c == "]" { depth-=1;result += "\n" + String(repeating:" ",count:depth*4);result.append(c) }
            else if c == "," { result += ",\n" + String(repeating:" ",count:depth*4) }
            else if c == ":" { result += ": " }
            else if c != " " { result.append(c) }
            index+=1
        }
        return result
    }
}
