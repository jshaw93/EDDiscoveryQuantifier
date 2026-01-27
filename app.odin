package discquant

import "core:fmt"
import "core:os/os2"
import "core:flags"
import "core:thread"
import "core:mem"
import vmem "core:mem/virtual"
import edlib "../odin-EDLib"
import "core:encoding/json"
import "core:time"
import "core:time/datetime"
import "core:strings"
import "../odintools/stringTools"

main :: proc() {
    when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

    arena : vmem.Arena
    allocErr := vmem.arena_init_growing(&arena)
    if allocErr != nil do panic("Allocation Error at line 34")
    defer vmem.arena_destroy(&arena)
    arenaAlloc := vmem.arena_allocator(&arena)

    Options :: struct {
        d : i64 `usage:"Days of exploration you would like to have broken down"`,
        e : bool `usage:"List all earthlikes discovered"`,
        w : bool `usage:"List all water worlds discovered"`,
        overflow : [dynamic]string `usage:"Any extra arguments go here."`
    }
    opt : Options
    defer delete(opt.overflow)

    flags.parse(&opt, os2.args[1:], strict=false, allocator=arenaAlloc)
    
    // Check if config.json exists, if it doesn't then make config.json, otherwise read config.json
    config : map[string]string
    defer delete(config)
    configExists : bool = os2.exists("config.json")
    if !configExists {
        buildErr : ConfigBuildError
        config, buildErr = buildConfig(arenaAlloc)
        if buildErr != nil {
            if buildErr == .MarshalError {
                fmt.println("Marshal Error on line 56")
            }
            if buildErr == .WriteError {
                fmt.println("Failed to write config.json on line 56")
            }
            return
        }
    } else {
        configRaw, success := os2.read_entire_file_from_filename("config.json", arenaAlloc)
        umErr := json.unmarshal(configRaw, &config, allocator=arenaAlloc)
        if umErr != nil {
            fmt.println("Unmarshall Error at line 68:", umErr)
            return
        }
    }

    // Open journal directory and find latest N journals, defined by -d at runtime
    logPath : string = config["JournalDirectory"]
    logsDir, err := os2.open(logPath)
    if err != nil {
        fmt.println("Open error line 77:", err)
        return
    }
    defer os2.close(logsDir)
    fileInfos, fErr := os2.read_dir(logsDir, -1, arenaAlloc)
    latestFiles : [dynamic]os2.File_Info
    defer delete(latestFiles)
    for fileInfo in fileInfos {
        if !strings.contains(fileInfo.name, ".log") do continue
        now, _ := time.time_to_datetime(time.now())
        makeTime, _ := time.time_to_datetime(fileInfo.creation_time)
        delta, _ := datetime.subtract_datetimes(now, makeTime)
        if delta.days <= opt.d do append(&latestFiles, fileInfo)
    }

    explorationData : ExplorationData
    explorationData.bodyFSSCounts = make(map[string]int, arenaAlloc)
    explorationData.bodyDSSCounts = make(map[string]int, arenaAlloc)
    explorationData.bioScanCounts = make(map[string]int, arenaAlloc)
    explorationData.earthlikes = make(map[string]u8, arenaAlloc)
    explorationData.waterWorlds = make(map[string]u8, arenaAlloc)
    
    pool : thread.Pool
    thread.pool_init(&pool, arenaAlloc, 4)
    defer thread.pool_destroy(&pool)
    thread.pool_start(&pool)

    fmt.printfln("  Reading %v log files from %s", len(latestFiles), logPath)

    for file in latestFiles {
        ptd := new(ParseTaskData)
        ptd.fileInfo = file
        ptd.allocator = arenaAlloc
        thread.pool_add_task(&pool, arenaAlloc, parseFilesTask, ptd)
    }
    thread.pool_finish(&pool)

    for !thread.pool_is_empty(&pool) {
        task, gotTask := thread.pool_pop_done(&pool)
        if !gotTask do continue
        dataPTR : ^ParseTaskData = transmute(^ParseTaskData)task.data
        data : ParseTaskData = dataPTR^
        tabulateData(&explorationData, data.explorationData)
        free(dataPTR)
    }
    thread.pool_shutdown(&pool)
    printDiscoveryValues(explorationData)
    if opt.e do printEarthlikes(explorationData)
    if opt.w do printWaterWorlds(explorationData)
}

ParseTaskData :: struct {
    fileInfo : os2.File_Info,
    allocator : mem.Allocator,
    explorationData : ExplorationData
}

ExplorationData :: struct {
    bodyFSSCounts : map[string]int,
    bodyDSSCounts : map[string]int,
    bioScanCounts : map[string]int,
    highestAnomalyBodyName : string,
    highestAnomalyBodyValue : f32,
    largestBody : string,
    largestBodyRadius : f32,
    smallestBody : string,
    smallestBodyRadius : f32,
    firstDiscovery : i32,
    firstMapped : i32,
    earthlikes : map[string]u8,
    waterWorlds : map[string]u8
}

parseFilesTask :: proc(task : thread.Task) {
    data := transmute(^ParseTaskData)task.data
    using data
    fileData, readSuccess := os2.read_entire_file_from_filename(fileInfo.fullpath)
    if !readSuccess {
        fmt.println("Read failed at line 155")
        return
    }
    fileLines := strings.split(string(fileData), "\r\n", context.temp_allocator)
    bodies := make(map[string]bool, allocator)
    defer delete(bodies)
    notScanned := make(map[string]bool, allocator)
    defer delete(notScanned)
    for line in fileLines {
        // scan, both FSS & DSS
        if strings.contains(line, "\"Scan\"") {
            scan, err := edlib.deserializeScanEvent(line, allocator)
            if err != nil do fmt.printfln("Unmarshall Error on line 168: %s | %s", err, fileInfo.name)
            if scan.PlanetClass == "" do continue
            if !bodies[scan.BodyName] do explorationData.bodyFSSCounts[scan.PlanetClass] += 1
            if bodies[scan.BodyName] {
                explorationData.bodyDSSCounts[scan.PlanetClass] += 1
                if !scan.WasMapped do explorationData.firstMapped += 1
            }
            else {
                bodies[scan.BodyName] = true
            }
            if scan.MeanAnomaly > explorationData.highestAnomalyBodyValue && scan.Landable {
                explorationData.highestAnomalyBodyValue = scan.MeanAnomaly
                explorationData.highestAnomalyBodyName = scan.BodyName
            }
            if scan.Radius > explorationData.largestBodyRadius {
                explorationData.largestBodyRadius = scan.Radius
                explorationData.largestBody = scan.BodyName
            }
            if scan.Radius < explorationData.smallestBodyRadius || explorationData.smallestBodyRadius == 0 {
                explorationData.smallestBodyRadius = scan.Radius
                explorationData.smallestBody = scan.BodyName
            }
            if !scan.WasDiscovered do explorationData.firstDiscovery += 1
            if !scan.WasMapped do notScanned[scan.BodyName] = true
            if scan.PlanetClass == "Earthlike body" do explorationData.earthlikes[scan.BodyName] = 1
            if scan.PlanetClass == "Water world" do explorationData.waterWorlds[scan.BodyName] = 1
        }
        // Organic scans, tabulate based on Genus name, e.g. "Stratum"
        if strings.contains(line, "\"ScanOrganic\"") {
            soEvent, err := edlib.deserializeScanOrganicEvent(line, allocator)
            if err != nil do fmt.println("Unmarshall Error on line 198:", err)
            if soEvent.ScanType != "Analyse" do continue
            explorationData.bioScanCounts[soEvent.Genus_Localised] += 1
        }
    }
    free_all(context.temp_allocator)
    return
}

printDiscoveryValues :: proc(explorationData : ExplorationData, allocator := context.allocator) {
    BODIES :: []string {"Earthlike body", "Water world", "Ammonia world", "High metal content body", "Metal rich body", "Rocky body", "Rocky ice body", "Icy body", "Water giant", "Gas giant with water based life", "Gas giant with ammonia based life", "Sudarsky class I gas giant", "Sudarsky class II gas giant", "Sudarsky class III gas giant", "Sudarsky class IV gas giant", "Sudarsky class V gas giant"}
    fmt.println("  ======================================")
    for bodyType in BODIES {
        if explorationData.bodyFSSCounts[bodyType] == 0 && explorationData.bodyDSSCounts[bodyType] == 0 do continue
        fssScans := stringTools.integerToStringDelimited(explorationData.bodyFSSCounts[bodyType], ',', context.temp_allocator)
        dssScans := stringTools.integerToStringDelimited(explorationData.bodyDSSCounts[bodyType], ',', context.temp_allocator)
        fmt.printfln("    %s FSS scans: %s | DSS scans: %s", bodyType, fssScans, dssScans)
    }
    fmt.println("  ======================================")
    largestSize := stringTools.floatToStringDelimited(explorationData.largestBodyRadius, ',', 1, context.temp_allocator)
    smallestSize := stringTools.floatToStringDelimited(explorationData.smallestBodyRadius, ',', 1, context.temp_allocator)
    fmt.printfln("    Largest planet discovered: %s at %skm radius", explorationData.largestBody, largestSize[:len(largestSize)-2])
    fmt.printfln("    Smallest planet discovered: %s at %skm radius", explorationData.smallestBody, smallestSize[:len(smallestSize)-2])
    fmt.printfln("    Weirdest planet discovered: %s", explorationData.highestAnomalyBodyName)
    fmt.println("  ======================================")
    discoveries := stringTools.integerToStringDelimited(explorationData.firstDiscovery, ',', context.temp_allocator)
    mapped := stringTools.integerToStringDelimited(explorationData.firstMapped, ',', context.temp_allocator)
    fmt.printfln("    # of bodies you discovered: %s | # of bodies you mapped first: %s", discoveries, mapped)
    for bio in explorationData.bioScanCounts {
        fmt.printfln("    Biological %s scans: %v", bio, explorationData.bioScanCounts[bio])
    }
    fmt.println("  ======================================")
    free_all(context.temp_allocator)
}

tabulateData :: proc(targetPTR : ^ExplorationData, data : ExplorationData) {
    for fss in data.bodyFSSCounts {
        targetPTR.bodyFSSCounts[fss] += data.bodyFSSCounts[fss]
    }
    for dss in data.bodyDSSCounts {
        targetPTR.bodyDSSCounts[dss] += data.bodyDSSCounts[dss]
    }
    for organicScan in data.bioScanCounts {
        targetPTR.bioScanCounts[organicScan] += data.bioScanCounts[organicScan]
    }
    for earthlike in data.earthlikes {
        targetPTR.earthlikes[earthlike] = data.earthlikes[earthlike]
    }
    for waterWorld in data.waterWorlds {
        targetPTR.waterWorlds[waterWorld] = data.waterWorlds[waterWorld]
    }
    if data.largestBodyRadius > targetPTR.largestBodyRadius {
        targetPTR.largestBodyRadius = data.largestBodyRadius
        targetPTR.largestBody = data.largestBody
    }
    if data.smallestBodyRadius < targetPTR.smallestBodyRadius || targetPTR.smallestBodyRadius == 0 {
        targetPTR.smallestBodyRadius = data.smallestBodyRadius
        targetPTR.smallestBody = data.smallestBody
    }
    if data.highestAnomalyBodyValue > targetPTR.highestAnomalyBodyValue {
        targetPTR.highestAnomalyBodyValue = data.highestAnomalyBodyValue
        targetPTR.highestAnomalyBodyName = data.highestAnomalyBodyName
    }
    targetPTR.firstDiscovery += data.firstDiscovery
    targetPTR.firstMapped += data.firstMapped
}

printEarthlikes :: proc(explorationData : ExplorationData) {
    fmt.println("    Earthlikes:")
    for earthlike in explorationData.earthlikes do fmt.printfln("      %s", earthlike)
    fmt.println("  ======================================")
}

printWaterWorlds :: proc(explorationData : ExplorationData) {
    fmt.println("    Water worlds:")
    for waterWorld in explorationData.waterWorlds do fmt.printfln("      %s", waterWorld)
    fmt.println("  ======================================")
}
