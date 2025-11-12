import json

labels = ["view.json","view_ex.json"]

for i in labels:
    iname = i.replace("json","jsonl")
    with open(i,"r",encoding = "utf8") as f:
        view = json.load(f)
    result = []
    for i in view:
        result.append(
            {
                "messages":[{"role":"user","content":i["messages"][0]["content"]},
                            {"role":"assistant","content":i["messages"][1]["content"]}
                           ],
                "images":i["images"]
            }
        )
    with open(iname, "w", encoding="utf-8") as f:
        for item in result:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")