import Foundation

public enum CompiledLlama32ToolReply {
    public static func parse(_ raw: String, offered: Set<String>) -> TaggedToolReply? {
        guard !offered.isEmpty, raw.utf16.count<=65_536 else { return nil }
        var body=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        // Android's Llama parser removes one native control prefix, not surrounding prose.
        if body.hasPrefix("<|python_tag|>") { body=String(body.dropFirst("<|python_tag|>".count)).trimmingCharacters(in:.whitespacesAndNewlines) }
        guard let data=body.data(using:.utf8),
              let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let name=object["name"] as? String, offered.contains(name),
              object["arguments"] == nil, let parameters=object["parameters"] as? [String:Any],
              let encoded=try? JSONSerialization.data(withJSONObject:parameters,options:[.sortedKeys]),
              let arguments=String(data:encoded,encoding:.utf8) else { return nil }
        return TaggedToolReply(content:"",calls:[AgentToolCall(id:name + "-0",name:name,argumentsJSON:arguments)])
    }
}
