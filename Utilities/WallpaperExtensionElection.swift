//  PlugInKit 选举结果解析
//
//  `pluginkit -m -v -i <id>` 输出每行一条登记记录，行首 `+` 表示该副本
//  当前被系统选中（elected），后跟 bundleID(version)、UUID、日期、路径：
//      +    com.waifux.app.wallpaperextension((null))	<UUID>	2026-09-17 ... /Applications/WaifuX.app/Contents/PlugIns/X.appex
//
//  路径是行内唯一以 "/" 开头的 token（bundleID/UUID/日期都不含斜杠），
//  因此从第一个 "/" 取到行尾即可，天然兼容含空格的安装路径。
//  参考 Mirage (GPL-3.0) 的 WallpaperExtensionRecord.parse。
//
//  本文件保持自包含（仅 Foundation），供回归脚本单独编译。

import Foundation

enum WallpaperExtensionElection {
    struct Record: Equatable {
        let path: String
        let isElected: Bool
    }

    static func parse(output: String) -> [Record] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(".appex"),
                  let slashIndex = line.firstIndex(of: "/") else { return nil }
            let path = String(line[slashIndex...])
            guard path.count > 1 else { return nil }
            return Record(path: path, isElected: rawLine.hasPrefix("+"))
        }
    }

    /// 目标路径的副本是否为当前被系统选中的登记。
    static func isElected(output: String, targetPath: String) -> Bool {
        let target = URL(fileURLWithPath: targetPath).standardizedFileURL.path
        return parse(output: output).contains { record in
            record.isElected
                && URL(fileURLWithPath: record.path).standardizedFileURL.path == target
        }
    }
}
