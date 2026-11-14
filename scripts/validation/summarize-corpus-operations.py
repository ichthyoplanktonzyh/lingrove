#!/usr/bin/env python3
"""Validate complete benchmark samples and produce reviewable JSON, CSV and Markdown tables."""
import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path
import statistics

LABELS = {
    "corpus.load.first": "生词本首次加载", "corpus.load.cached": "生词本重复加载",
    "browse.list.first": "列表首次排序与行准备", "browse.list.cached": "列表缓存读取",
    "browse.expand.one": "展开一个多义词", "browse.filter.language": "按语言筛选",
    "browse.filter.tag": "按标签筛选", "browse.literal.query": "列表文字筛选",
    "browse.meanings.first": "共享义浏览准备", "browse.category.outline": "分类大纲准备",
    "browse.unclassified": "未分类义项准备", "search.prepare.first": "首次检索文档准备",
    "search.keyword.query": "关键词检索", "search.prepare.one.receipt": "个人笔记变化后的检索准备（检索文本未变）",
    "search.prepare.after.favorite": "收藏后的检索准备", "search.prepare.after.remove": "移除义项后的检索准备",
    "browse.list.after.favorite": "收藏后的列表准备", "browse.list.after.remove": "移除义项后的列表准备",
    "graph.taxonomy.first": "分类图谱首次投影", "graph.taxonomy.cached": "分类图谱缓存读取",
    "graph.entries.first": "词条图谱首次投影", "favorite.translation.first": "收藏无上下文翻译（首次写入）",
    "favorite.translation.repeat": "收藏另一无上下文翻译（后续写入）",
    "favorite.context.first": "收藏带例句翻译（首次写入）",
    "favorite.context.repeat": "收藏另一带例句翻译（后续写入）",
    "favorite.context.existing": "为已有义项收藏例句", "favorite.context.remove": "取消收藏一条例句",
    "editor.save.note": "保存个人笔记", "editor.save.translation": "保存义项翻译",
    "sense.create": "新增有内容的义项",
    "sense.merge": "合并义项", "sense.merge.undo": "撤销义项合并",
    "sense.remove.mapped": "移除前部有关联义项（第59词条）", "sense.remove.unmapped": "移除尾部无关联义项（倒数第2词条）",
    "sense.remove.enrolled": "从生词本移除已加入复习的义项", "entry.remove": "从生词本移除整个词条",
    "entry.create.manual": "手工创建一个词条", "entry.import.50": "批量添加50个词条",
    "entry.import.50.again": "再次手工导入同样50行（新增50义项）", "tag.remove.global": "全库删除一个标签",
    "image.prepare": "准备一张合成图片", "image.attach.save": "保存带图片的义项说明", "image.read": "读取已存图片",
    "meaning.edit.shared": "编辑关联12个义项的共享义", "meaning.create": "新增共享义",
    "meaning.associate": "将义项关联到共享义", "meaning.categorize": "将共享义加入分类",
    "category.edit": "编辑分类说明", "meaning.remove": "删除共享义及其关联",
    "cli.status": "CLI读取库状态", "cli.list.page": "CLI读取50条列表页",
    "cli.list.query": "CLI查询列表", "cli.entry.read": "CLI读取一个词条", "cli.sense.read": "CLI读取一个义项",
    "cli.entries.read25": "CLI读取25个词条", "cli.capture50": "CLI批量保存50个词条",
    "cli.capture50.idempotent": "CLI重试同一批次（幂等）", "review.open.first": "首次进入复习",
    "review.open.repeat": "关闭后再次进入复习", "review.enroll.one": "复习页可见时加入义项并刷新",
    "review.enroll.one.hidden": "生词本内将单个义项加入复习（复习页隐藏）",
    "review.participation": "读取单个义项复习状态", "review.content.search": "复习内容列表检索",
    "review.note.edit.and.refresh": "编辑单条 Note 并刷新复习页",
    "review.type.edit.shared.and.refresh": "编辑共享 Note Type 并刷新复习页",
    "review.practice.start": "开始单项复习", "review.answer.reveal": "显示答案",
    "review.rate.and.refresh": "评分并刷新复习状态", "review.rating.undo.and.refresh": "撤销评分并刷新",
    "review.pause.and.refresh": "暂停复习并刷新", "review.resume.and.refresh": "恢复复习并刷新",
    "review.withdraw.and.refresh": "退出复习并刷新", "review.navigation.resume": "切回复习页并刷新",
    "progress.open.first": "首次进入进度页", "progress.open.repeat": "再次进入进度页", "progress.reload": "刷新进度统计",
    "export.selected.prepare": "准备选中约50义项的CSV导出", "export.selected.write": "写出已准备的CSV文件",
    "backup.full.write": "生成并写出完整语料备份", "backup.full.restore": "校验并恢复完整语料备份",
    "favorite.stage.plan": "收藏分段：生成待保存词条", "favorite.stage.transaction": "收藏分段：引擎事务",
    "favorite.stage.readindex": "收藏分段：UI读取索引增量", "sense.remove.stage.transaction": "移除义项分段：引擎事务",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--tail-run", type=Path, help="A passing scoped rerun after the known expired test-envelope interruption")
    args = parser.parse_args()
    base = args.run.resolve()
    identity = json.loads((base / "identity.json").read_text())
    validation = {}
    interrupted = False
    for name in ("measurements", "focused"):
        execution = json.loads((base / (name + "-summary.log")).read_text())
        passed = execution.get("result") == "Passed" and execution.get("passedTests", 0) > 0 and not execution.get("skippedTests")
        if not passed:
            failures = execution.get("testFailures", [])
            known_envelope = name == "measurements" and args.tail_run is not None and execution.get("failedTests") == 1 \
                and len(failures) == 1 and "repeated.ok" in failures[0].get("failureText", "") \
                and ".timeout" in failures[0].get("failureText", "")
            assert known_envelope, "Unverified execution cannot produce the final report"
            interrupted = True
        validation[name] = {key: execution.get(key) for key in
            ("result", "passedTests", "failedTests", "skippedTests", "startTime", "finishTime")}
        devices = execution.get("devicesAndConfigurations", [])
        if devices:
            device = devices[0].get("device", {})
            validation[name]["platform"] = {key: device.get(key) for key in
                ("modelName", "osVersion", "osBuildNumber", "architecture")}
    if interrupted:
        validation["measurements"]["harnessInterruption"] = "Expired test transport envelope reused after a >30-second save; successful prefix preserved"
    expected_sizes = [int(value) for value in identity["sizes"].split(",")]
    samples, outcomes = [], []
    for folder, mode, trial_count in [("measurements", "scan", 1), ("focused", "focused", identity["focusedTrials"])]:
        trial_ids = set(range(1, trial_count + 1))
        for line in (base / folder / "samples.jsonl").read_text().splitlines():
            samples.append(dict(json.loads(line), measurementMode=mode))
        mode_outcomes = [dict(json.loads(line), measurementMode=mode)
            for line in (base / folder / "outcomes.jsonl").read_text().splitlines()]
        assert len(mode_outcomes) == len(expected_sizes) * trial_count
        assert {(row["entries"], row["trial"]) for row in mode_outcomes} == \
            {(size, trial) for size in expected_sizes for trial in trial_ids}
        outcomes.extend(mode_outcomes)
    if args.tail_run:
        tail = args.tail_run.resolve()
        execution = json.loads((tail / "tail-summary.log").read_text())
        assert execution.get("result") == "Passed" and execution.get("passedTests", 0) > 0 and not execution.get("skippedTests")
        original_hashes = json.loads((base / "source-hashes.json").read_text())
        tail_hashes = json.loads((tail / "source-hashes.json").read_text())
        for name, digest in original_hashes.items():
            if name.startswith(("Lingrove/", "Packages/")):
                assert tail_hashes.get(name) == digest, "Product code changed during scoped recovery: " + name
        validation["tail"] = {key: execution.get(key) for key in
            ("result", "passedTests", "failedTests", "skippedTests", "startTime", "finishTime")}
        validation["tail"]["scope"] = "CLI with a fresh retry envelope, then Review/Progress/export/backup/stages on a fresh generated seed"
        for line in (tail / "tail/samples.jsonl").read_text().splitlines():
            samples.append(dict(json.loads(line), measurementMode="tail"))
    groups = defaultdict(list)
    order = []
    for sample in samples:
        name = sample["operation"]
        if name not in order:
            order.append(name)
        groups[(name, sample["entries"], sample["measurementMode"])].append(sample)
        assert sample["milliseconds"] >= 0
    assert set(order) == set(LABELS), "Operation inventory and sample labels differ: " + str(set(order) ^ set(LABELS))
    operations = []
    focused_names = {row["operation"] for row in samples if row["measurementMode"] == "focused"}
    for name in order:
        mode = "focused" if name in focused_names else "scan"
        expected_trials = set(range(1, identity["focusedTrials"] + 1)) if mode == "focused" else {1}
        operation = {"id": name, "label": LABELS[name], "measurementMode": mode, "sizes": {}}
        for size in expected_sizes:
            scan_mode = "tail" if groups[(name, size, "tail")] else "scan"
            selected_mode = "focused" if mode == "focused" else scan_mode
            rows = groups[(name, size, selected_mode)]
            assert len(rows) == len(expected_trials) and {row["trial"] for row in rows} == expected_trials, (name, size)
            assert len(groups[(name, size, scan_mode)]) == 1
            values = [row["milliseconds"] for row in rows]
            operation["layer"] = rows[0]["layer"]
            operation["sizes"][str(size)] = {"samples": len(rows), "medianMs": statistics.median(values),
                "minMs": min(values), "maxMs": max(values), "rawMs": values,
                "visibleEntriesBefore": sorted({row.get("visibleEntriesBefore", size) for row in rows}),
                "visibleEntriesAfter": sorted({row.get("visibleEntriesAfter", size) for row in rows}),
                "statistic": "median" if len(rows) > 1 else "single observation",
                "measurementMode": selected_mode,
                "scanMs": groups[(name, size, scan_mode)][0]["milliseconds"]}
            rejected = [row for row in outcomes if row["operation"] == name and row["entries"] == size
                        and row["measurementMode"] == selected_mode and not row["succeeded"]]
            operation["sizes"][str(size)]["rejectedTrials"] = rejected
        operations.append(operation)
    fixtures = {str(size): json.loads((base / ("measurements/fixture-" + str(size) + ".json")).read_text()) for size in expected_sizes}
    excluded = [row for row in samples if interrupted and row["measurementMode"] == "scan" and
        row["entries"] == 20000 and row["operation"] == "cli.capture50.idempotent"]
    for row in excluded:
        row["excludedFromStatistics"] = "Expired test envelope; replaced by passing fresh-envelope rerun"
    result = {"identity": identity, "validation": validation, "outcomes": outcomes, "excludedSamples": excluded,
              "fixtures": fixtures, "operationCount": len(operations),
              "sampleCount": len(samples), "focusedOperationCount": len(focused_names), "operations": operations}
    (base / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    (base / "all-samples.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in samples))
    with (base / "summary.csv").open("w") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(["operation", "label", "layer", "seedEntries", "visibleEntriesBefore", "visibleEntriesAfter",
                         "samples", "rejectedSamples", "measurementMode", "statistic", "valueMs", "minMs", "maxMs", "scanMs"])
        for operation in operations:
            for size, stats in operation["sizes"].items():
                writer.writerow([operation["id"], operation["label"], operation["layer"], size,
                    ",".join(map(str, stats["visibleEntriesBefore"])), ",".join(map(str, stats["visibleEntriesAfter"])),
                    stats["samples"], len(stats["rejectedTrials"]), stats["measurementMode"], stats["statistic"], stats["medianMs"],
                    stats["minMs"], stats["maxMs"], stats["scanMs"]])
    lines = ["# 合成大库操作耗时测量", "", "配置：Release / arm64 / ENABLE_TESTABILITY=YES；所有样本通过测试调用生产业务代码，没有模拟点击。",
        "", f"共 {len(operations)} 个计时窗口、{len(samples)} 个样本。其中 {len(focused_names)} 项每档独立重复 {identity['focusedTrials']} 次；其余为每档单次完整扫描。",
        "", "表中列名是初始词条数量，单位为毫秒。样本数大于1时显示中位数（最大值）；样本数为1时只显示单次观察值，没有统计稳定性保证。重复测量使用接近种子状态的独立副本；扫描内按固定顺序执行全部操作。",
        "", "首次加载指新连接和新模型的首次访问；不含应用组合根/Repository初始化，也没有清空操作系统文件缓存。后续写入使用另一条等价内容，不是重复保存造成的无操作。",
        "", "每个试次从同一档合成种子重新复制，按固定顺序执行；试次之间互不累计。单次试次内会新增和移除少量内容，原始样本记录每项执行前后的可见词条数。",
        "", "存储总耗时计到 VocabularyStore 应用结果并发布状态为止；不含 SwiftUI 实际绘制、等待动画、下载、远端网络或模型生成。检索、列表和图谱投影另行列出。CLI不含进程启动和邮箱IPC。",
        "", "阶段窗口使用独立调用，不能将不同调用的中位数相加解释成一次请求的总耗时。图片用80×40的合成PNG，不能代表大图片或媒体密集库。",
        "", "两组删除样本同时改变了位置与语义关联：第59词条有关联，倒数第2词条无关联。它们是两个真实场景，不是隔离关联因素的对照实验，不能将差异全部归因于关联。引擎分段删除使用第65词条。",
        "", "微秒量级的缓存读取接近测试调用与计时开销，不据此比较微小差异。",
        "", "个人笔记变化的检索计时没有改变检索字段，主要验证避免多余重建；它不能代表义项定义或共享义改变后的检索重建耗时。",
        "", "## 合成数据", "", "| 项目 | " + " | ".join(map(str, expected_sizes)) + " |", "|---|" + "---:|" * len(expected_sizes)]
    for key in next(iter(fixtures.values())):
        lines.append("| " + key + " | " + " | ".join(str(fixtures[str(size)][key]) for size in expected_sizes) + " |")
    if interrupted:
        lines += ["", "## 分段补测说明", "",
            "原完整扫描在2万档的CLI重试处因测试复用已过期的30秒传输请求而中断；原生执行记录为 Failed，不能称为一次完整通过。",
            "已保留全部已完成前缀。补测保持产品源代码逐文件哈希不变，只修正重试包的请求ID/有效期，幂等键不变；在新的同规模生成副本上执行CLI及复习、进度、导出、备份和分段测量，补测原生执行通过。",
            "统计优先使用通过的高频重复样本；其余同名尾段用补测覆盖。补测未串联前部编辑，状态/操作顺序不同，实际可见词条数记录在原始数据中。",
            "原过期拒绝的耗时被明确排除，不当作幂等重试成功耗时。结果是组合测量检查点，原失败记录与补测结果均保留在JSON validation字段。"]
    lines += ["", "## 全部操作", "", "| 操作 | 层次 | 每档样本数 | " + " | ".join(map(str, expected_sizes)) + " |",
        "|---|---|---:|" + "---:|" * len(expected_sizes)]
    for operation in operations:
        cells = [(f"{operation['sizes'][str(size)]['medianMs']:.3f} ({operation['sizes'][str(size)]['maxMs']:.3f})"
                  if operation['sizes'][str(size)]['samples'] > 1 else f"{operation['sizes'][str(size)]['medianMs']:.3f}") +
                 (" 拒绝请求" if operation['sizes'][str(size)]['rejectedTrials'] else "") +
                 (" †" if operation['sizes'][str(size)]['measurementMode'] == "tail" else "") for size in expected_sizes]
        lines.append("| " + operation["label"] + " | " + operation["layer"] + " | " +
            str(operation['sizes'][str(expected_sizes[0])]['samples']) + " | " + " | ".join(cells) + " |")
    lines += ["", "全部原始样本（含采样模式）：`all-samples.jsonl`；完整统计：`summary.json`、`summary.csv`。",
              "", "未测：实际像素/帧率、真实屏幕交互延迟、GGUF生成和向量推理、语音合成/播放、OCR、云端/Anki网络往返、移动端。"]
    if interrupted:
        lines += ["", f"† 表示采用独立尾段补测的单次观察值，未串联原扫描的全部前置编辑。{len(samples)}条原始记录中有{len(excluded)}条过期包拒绝已从成功耗时统计中排除。"]
    rejected = [row for row in outcomes if not row["succeeded"]]
    if rejected:
        lines += ["", "## 未成功的操作", "", "下列计时是拒绝请求的耗时，不能当作成功完成操作的性能。测试另行验证拒绝后目标义项和库版本未改变。", ""]
        for operation in sorted({row["operation"] for row in rejected}):
            rows = [row for row in rejected if row["operation"] == operation]
            lines.append(f"- `{operation}`：{len(rows)} 次拒绝；错误：" + "；".join(sorted({row["message"] for row in rows})))
    (base / "report.md").write_text("\n".join(lines) + "\n")
    print(json.dumps({"operations": len(operations), "samples": len(samples), "report": str(base / "report.md")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
