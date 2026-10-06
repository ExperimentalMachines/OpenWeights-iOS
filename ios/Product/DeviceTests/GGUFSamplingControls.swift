import XCTest
@testable import OpenWeights

extension ProductTests {
    func testNativeGGUFOwnedLogitsIndependentFiltersAndMaximumTies() throws {
        var observations: [[String:Any]] = [], completed = false
        defer {
            let value: [String:Any] = ["purpose":"native-llama-owned-logits-independent-filters-and-tied-maxima", "completed":completed,
                "observations":observations,
                "limitations":["Uses actual llama.cpp samplers linked from the existing product host, with owned logits. No model, CPU/Metal inference or quality/speed measurement.",
                    "Top P and penalties are omitted. Temperature is 1, distribution seed 42 and 128 draws per case. Allowed sets are derived independently from exp(logit - maximum logit)."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Owned llama sampler logits"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let cases: [(String,Int32,Float,Set<Int>,Bool)] = [
            ("unfiltered",0,0,[0,1,2,3],false), ("top-k-one",1,0,[0],false),
            ("min-p-half",0,0.5,[0],false), ("min-p-one-fifth",0,0.2,[0,1],false),
            ("min-p-one-tied-maxima",0,1,[0,1],true)]
        for (stage,topK,minP,allowed,tied) in cases {
            let logits: [NSNumber] = tied ? [4,4,1,0] : [4,3,1,0]
            let value = OWSamplingProbe.sampleLogits(logits,topK:topK,minP:minP,seed:42,draws:128)
            let retained = try XCTUnwrap(value["retainedTokenIDs"] as? [Int])
            let selected = try XCTUnwrap(value["sampledTokenIDs"] as? [Int])
            XCTAssertEqual(Set(retained),allowed); XCTAssertEqual(selected.count,128)
            XCTAssertTrue(selected.allSatisfy { allowed.contains($0) })
            var counts = [Int](repeating:0,count:4)
            for id in selected { counts[id] += 1 }
            if stage == "unfiltered" { XCTAssertGreaterThan(counts[1]+counts[2]+counts[3],0) }
            if stage == "min-p-one-fifth" || tied { XCTAssertGreaterThan(counts[0],0); XCTAssertGreaterThan(counts[1],0) }
            observations.append(["stage":stage, "logits":logits, "topK":topK, "minP":minP,
                "allowedTokenIDs":allowed.sorted(), "retainedTokenIDs":retained, "observedCounts":counts, "seed":42])
        }
        completed = true
    }
}
