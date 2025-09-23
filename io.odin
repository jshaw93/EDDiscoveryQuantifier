package discquant

import "core:os"
import "core:strings"
import "core:encoding/json"

buildConfig :: proc(allocator := context.allocator) -> (config : map[string]string, err : ConfigBuildError) {
    baseConfig := make(map[string]string, allocator)
    user := os.get_env("USERPROFILE", allocator)
    logPath : string = strings.concatenate({user, "\\Saved Games\\Frontier Developments\\Elite Dangerous"}, allocator)
    baseConfig["JournalDirectory"] = logPath
    mOpt : json.Marshal_Options
    mOpt.pretty = true
    data, mErr := json.marshal(baseConfig, mOpt, allocator)
    if mErr != nil {
        return baseConfig, .MarshalError
    }
    success := os.write_entire_file("config.json", data)
    if !success {
        return baseConfig, .WriteError
    }
    return baseConfig, nil
}
