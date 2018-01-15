--
-- actions/fastbuild/fastbuild.lua
-- Extend the existing exporters with support for FASTBuild
-- Copyright (c) 2017-2017 Daniel Penkała
--

    local p = premake
    p.fastbuild.fbprj = { }

    local tree = p.tree
    local project = p.project
    local config = p.config
    local fileconfig = p.fileconfig

    local fastbuild = p.fastbuild
    local fbuild = p.fastbuild
    local fbprj = fastbuild.fbprj

    local f = fastbuild.utils
    local m = p.fastbuild.fbprj


---
-- Helper function to output values
---

    m.element = function(value, info, ...)
        if info then
            if #{...} ~= 0 then
                info = info:format(...)
            end
            fastbuild.struct_pair_append("' %s' // %s", value, info)
        else
            fastbuild.struct_pair_append("' %s'", value)
        end
    end

--
-- Add namespace for element definition lists for p.callArray()
--

    m.elements = {}
    m.conditionalElements = {}

--
-- Generate a Fastbuild project, with support for the new platforms API.
--

    m.elements.project = function(prj)
        return {
            m.header,
            m.configurations,
            m.buildStepCommands,
            m.files,
            m.projectBinary,
            m.projectAliases,
            iif(_OPTIONS["fb-vstudio"], m.projectVisualStudio, fbuild.fmap.pass)
        }
    end

    local function hasToolchain(prj)
        local wks = prj.workspace
        local configs_have_compilers = true

        for cfg in project.eachconfig(prj) do
            configs_have_compilers = configs_have_compilers and wks.compilers[fbuild.targetCompilerPlatform(cfg)] ~= nil
        end

        return configs_have_compilers
    end

    function m.generate(prj)
        prj.unity_builds = _OPTIONS['fb-unity-builds'] ~= nil and (prj.flags.FBUnityBuild or prj.flags.UnityBuildEnable)

        local has = hasToolchain(prj)
        if has then
            p.callArray(m.elements.project, prj)
        end
    end

    function m.header(prj)
        f.section("FASTBuild Project: %s", prj.name)
    end


---
-- Wraps a function into a proxy so it can be stored in a callArray
---
    local function call(func, ...)
        local args = { ... }
        return function()
            func(unpack(args))
        end
    end

---
-- Configurations
---

    m.elements.clCompile = function(cfg, prj)
        return {
            m.warningLevel,
            m.treatWarningAsError,
            m.debugInformationFormat,
            m.optimization,
            m.intrinsicFunctions,
            m.minimalRebuild,
            m.openMPSupport,
            m.enableFunctionLevelLinking,
            m.runtimeLibrary,
            m.clCompilePreprocessorDefinitions,
            m.clCompileAdditionalIncludeDirectories,
            m.exceptionHandling,
            m.runtimeTypeInfo,
            m.additionalCompileOptions,
            m.precompiledHeader
        }
    end

    m.elements.link = function(cfg, prj)
        if cfg.kind == p.STATICLIB then
            return {
                m.additionalLinkOptions,
            }
        else
            return {
                m.generateDebugInformation,
                m.linkIncremental,
                m.additionalDependencies,
                m.additionalLibraryDirectories,
                m.optimizeReferences,
                m.enableCOMDATFolding,
                m.delayLoadDlls,
                m.entryPointSymbol,
                m.additionalLinkOptions,
                -- TODO?: /LARGEADDRESSAWARE /OPT:NOREF /OPT:NOICF /ERRORREPORT:PROMPT
            }
        end
    end

    function m.configurations(prj)
        local toolchains = prj.workspace.toolchains

        local link_deps = { }
        for _, ref in pairs(project.getdependencies(prj, "linkOnly")) do
            link_deps[ref.name] = true
        end

        for cfg in project.eachconfig(prj) do
            p.push(".%s_%s_prebuild_deps = {", prj.name, fastbuild.projectPlatform(cfg))
            p.pop("}\n")
        end

        f.section("Configurations")
        for cfg in project.eachconfig(prj) do
            f.struct_begin("config_%s_%s", prj.name, fastbuild.projectPlatform(cfg))
            p.x("Using( .%s )", fbuild.targetCompilerPlatformStruct(cfg))
            p.w()

            p.x(".CompilerOptions + ''")
            p.callArray(m.elements.clCompile, cfg, prj)
            p.w()
            p.x(".PCHOptions + ''")
            p.callArray(m.elements.clCompile, cfg, prj)
            p.w()

            -- Linker options
            if cfg.kind == p.STATICLIB then
                p.x(".LibrarianOptions + ''")
                p.callArray(m.elements.link , cfg, prj)
            else
                p.x(".LinkerOptions + ''")
                p.callArray(m.elements.link , cfg, prj)
            end

            f.struct_end()
        end

        for cfg in project.eachconfig(prj) do
            p.x(".%s_%s_compile_dependencies = { }", prj.name, fastbuild.projectPlatform(cfg));
            p.w()
        end
    end

    function m.warningLevel(cfg)
        local warning = cfg.warnings or "Level3"
        local map = { Off = "/W0", Extra = "/W4", All = "/Wal", Level3 = "/W3" }

        m.element(map[warning], "Warning level: %s", warning)
    end

    function m.treatWarningAsError(cfg)
        if cfg.flags.FatalCompileWarnings and cfg.warnings ~= p.OFF then
            m.element("/WX", "Warnings as errors")
        end
    end

    function m.optimization(cfg)
        local map = { Off = "/Od", On = "/Ox", Debug = "/Od", Full = "/Ox", Size = "/O1", Speed = "/O2" }
        local value = map[cfg.optimize]
        if value then
            m.element(value, "Optimization: %s", cfg.optimize or "None")
        end
    end

    function m.clCompilePreprocessorDefinitions(cfg)
        local defines = cfg.defines
        if cfg.exceptionhandling == p.OFF then
            defines = table.join(defines, "_HAS_EXCEPTIONS=0")
        end
        m.preprocessorDefinitions(cfg, defines, true)
    end

    function m.preprocessorDefinitions(cfg, defines, escapeQuotes)
        if #defines > 0 then

            table.foreachi(defines, function(define)
                if escapeQuotes then
                    define = define:gsub('"', '\\"')
                end

                m.element(('/D"%s"'):format(define))
            end)

        end
    end

    function m.clCompileAdditionalIncludeDirectories(cfg)
        m.additionalIncludeDirectories(cfg, cfg.includedirs)
    end

    function m.additionalIncludeDirectories(cfg, includedirs)
        local wks = cfg.workspace
        if not wks then -- we got a fcfg
            local prjcfg, fcfg = p.config.normalize(cfg)
            wks = prjcfg.workspace
            assert(fcfg)
        end

        if #includedirs > 0 then
            local dirs = fbuild.path(wks, includedirs)
            if #dirs > 0 then
                for _, dir in pairs(dirs) do
                    m.element(('/I"%s"'):format(dir))
                end
            end
        end
    end

    --
    -- Enables Delayed Dll Loading
    function m.delayLoadDlls(cfg)
        if cfg.delayloaddlls then
            local mapped = { }
            for _, dll in pairs(cfg.delayloaddlls) do
                mapped[dll] = true
            end

            local sorted = { }
            for dll, _ in pairs(mapped) do
                table.insert(sorted, dll)
            end

            table.sort(sorted, function(e1, e2) return e1 < e2 end)
            for _, dll in pairs(sorted) do
                m.element(('/DELAYLOAD:"%s"'):format(dll), "Load DLL on first function call.")
            end
        end
    end

    function m.debugInformationFormat(cfg)
        local value
        local format

        if (cfg.symbols == p.ON) or (cfg.symbols == "FastLink") then
            if cfg.debugformat == "c7" then
                value = "/Z7"
                format = "OldFormat"

            elseif cfg.architecture == "x86_64" or
                   cfg.clr ~= p.OFF or
                   config.isOptimizedBuild(cfg) or
                   cfg.editandcontinue == p.OFF then
                value = "/Zi"
                format = "Program Database"

            else
                value = "/ZI"
                format = "Edit and continue"
            end
            m.element(value, "Debug format: %s", format)
        end
    end

    function m.exceptionHandling(cfg)
        if cfg.exceptionhandling == p.OFF then
            -- m.element("", "ExceptionHandling: %s", cfg.exceptionhandling)
        elseif cfg.exceptionhandling == "SEH" then
            m.element("/EHa", "ExceptionHandling: %s", cfg.exceptionhandling)
        elseif cfg.exceptionhandling == "On" then
            m.element("/EHsc", "ExceptionHandling: %s", cfg.exceptionhandling)
        elseif cfg.exceptionhandling == "CThrow" then
            m.element("/EHs", "ExceptionHandling: %s", cfg.exceptionhandling)
        else
            m.element("/EHsc", "ExceptionHandling: %s (default)", cfg.exceptionhandling)
        end
    end

    function m.linkIncremental(cfg)
        local canLinkIncremental = config.canLinkIncremental(cfg)
        if cfg.kind ~= p.STATICLIB and canLinkIncremental then
            m.element("/INCREMENTAL", "Incremental linking: %s", tostring(canLinkIncremental))
        end
    end

    function m.optimizeReferences(cfg)
        if config.isOptimizedBuild(cfg)  then
            if cfg.optimizereferences ~= "No" then
                m.element("/OPT:REF", "Optimize References: %s", "Yes")

            else
                m.element("/OPT:NOREF", "Optimize References: %s", "No")

            end

        elseif cfg.optimizereferences == "Yes" then
            m.element("/OPT:REF", "Optimize References: %s", "Yes")

        else
            m.element("/OPT:NOREF", "Optimize References: %s", "No")

        end
    end

    function m.enableCOMDATFolding(cfg)
        if config.isOptimizedBuild(cfg)  then
            if cfg.comdatfolding ~= "No" then
                m.element("/OPT:ICF", "Optimize References: %s", "Yes")

            else
                m.element("/OPT:NOICF", "Optimize References: %s", "No")

            end

        elseif cfg.comdatfolding == "Yes" then
            m.element("/OPT:ICF", "Optimize References: %s", "Yes")

        else
            m.element("/OPT:NOICF", "Optimize References: %s", "No")

        end
    end

    function m.intrinsicFunctions(cfg)
        if cfg.intrinsicfunctions ~= nil then
            if cfg.intrinsicfunctions then
                m.element("/Oi", "Intrinsics functions: %s", "true")

            end

        elseif config.isOptimizedBuild(cfg) then
            m.element("/Oi", "Intrinsics functions: %s", "true")

        end
    end

    function m.openMPSupport(cfg)
        local map = { Yes = "/openmp", No = "/openmp-" }
        if map[cfg.openmp] then
            m.element(map[cfg.openmp], "Open MP Support: %s", cfg.openmp)
        end
    end

    function m.enableFunctionLevelLinking(cfg)
        local map = { Yes = "/Gy", No = "/Gy-" }
        if map[cfg.functionlevellinking] then
            m.element(map[cfg.functionlevellinking], "Function Level Linking: %s", cfg.functionlevellinking)
        end
    end

    function m.minimalRebuild(cfg)
        if config.isOptimizedBuild(cfg) or
           cfg.flags.NoMinimalRebuild or
           cfg.flags.MultiProcessorCompile or
           cfg.debugformat == p.C7
        then
            m.element("/Gm-", "Minimal rebuild: Disabled")
        end
    end

    function m.runtimeLibrary(cfg)
        local runtimes = {
            StaticDebug   = "/MTd",
            StaticRelease = "/MT",
            StaticDLLDebug = "/MDd",
            StaticDLLRelease = "/MD",
            SharedDebug = "/MDd",
            SharedRelease = "/MD"
        }
        local runtime = runtimes[config.getruntime(cfg)] or "/MDd"
        if runtime then
            m.element(runtime, "Runtime library: %s", config.getruntime(cfg) or "StaticDLLDebug")
        end
    end

    function m.programDatabaseFilename(cfg, prj, name)
        local path = fastbuild.path(prj, cfg.objdir .. "/" .. iif(name, name .. ".pdb", ""))
        m.element('/Fd"' .. path .. '"', "Program database file directory")
    end

    function m.cppDialect(cfg)
        if (cfg.cppdialect == "C++14") then
            m.element("/std:c++14", "C++ Standard: %s", cfg.cppdialect)
        elseif (cfg.cppdialect == "C++17") then
            m.element("/std:c++latest", "C++ Standard: %s", cfg.cppdialect)
        end
    end

    function m.additionalCompileOptions(cfg)
        local opts = cfg.buildoptions

        m.cppDialect(cfg)

        if #opts > 0 then

            local found_opts = { }
            local unique_opts = { }
            for _, opt in pairs(opts) do
                if not found_opts[opt] then
                    found_opts[opt] = true
                    table.insert(unique_opts, opt)
                end
            end

            table.sort(unique_opts, function(e1, e2) return e1 < e2 end)

            for _, opt in pairs(unique_opts) do
                m.element(opt)
            end
        end
    end

    function m.additionalLinkOptions(cfg)
        local opts = cfg.linkoptions
        if #opts > 0 then

            local found_opts = { }
            local unique_opts = { }
            for _, opt in pairs(opts) do
                if not found_opts[opt] then
                    found_opts[opt] = true
                    table.insert(unique_opts, opt)
                end
            end

            table.sort(unique_opts, function(e1, e2) return e1 < e2 end)

            for _, opt in pairs(unique_opts) do
                m.element(opt)
            end
        end
    end

    function m.precompiledHeader(cfg)
        local prjcfg, filecfg = p.config.normalize(cfg)
        if filecfg then

            if prjcfg.pchsource and filecfg.flags.NoPCH then
                m.element("", "PrecompiledHeader disabled")
                return
            end

            if prjcfg.pchsource == filecfg.abspath and not prjcfg.flags.NoPCH then
                filecfg.pchsource = true
            end
        end
    end

    function m.unityBuildDisabled(cfg)
        local prjcfg, filecfg = p.config.normalize(cfg)
        if filecfg then
            if filecfg.flags.FBUnityBuildDisabled then
                m.element("", "FastBuild UnityBuild disabled")
            end
        end
    end

    function m.unityTag(cfg)
        local prjcfg, filecfg = p.config.normalize(cfg)
        if filecfg and filecfg.fbtag then
            m.element("", "Tag: %s", filecfg.fbtag)
        end
    end


---
-- Linker options
---
    function m.generateDebugInformation(cfg)
        local lookup = {}

        if _ACTION == "fastbuild" then
            lookup[p.OFF]      = nil
            lookup[p.ON]       = "/DEBUG"
            lookup["FastLink"] = "/DEBUG:FASTLINK"
            lookup["Full"]     = "/DEBUG:FULL"
        end

        local value = lookup[cfg.symbols]
        if value then
            m.element(value, "Generate debug information: %s", cfg.symbols)
        end
    end


---------------------------------------------------------------------------
--
-- Build step commands (pre-build, pre-link, post-build)
--
---------------------------------------------------------------------------

    m.elements.buildsteps = function(cfg)
        return {
            m.preBuildCommands,
            m.preLinkCommands,
            m.postBuildCommands
        }
    end

    function m.buildStepCommands(prj)
        local n = 0
        for cfg in project.eachconfig(prj) do
            n = n + 1
            p.callArray(m.elements.buildsteps, tostring(n), cfg, prj)
        end

        p.callArray(m.elements.buildsteps, "prj", prj)
    end

    function m.preBuildCommands(nth, cfg, prj)
        local prj_cmds = { }
        if prj then
            for _, cmd in ipairs(prj.fbprebuildcommands) do
                prj_cmds[cmd.output] = true
            end
        end

        for _, cmd in ipairs(cfg.fbprebuildcommands) do
            if not prj_cmds[cmd.output] then
                m.emitExecFunctionCall("prebuild_" .. nth, cfg, cmd)
            end
        end
    end

    m.elements.exec = function(cfg, cmds)
        return {
            m.emitExecExecutable,
            m.emitExecArguments,
            m.emitExecInput,
            m.emitExecOutput,
        }
    end

    function m.emitExecFunctionCall(type, cfg, cmd)
        local exec_target = fbuild._targetName(cfg, type, "exec")
        fbuild.emitFunction("Exec", exec_target, m.elements.exec, nil, cfg, cmd)
        m.emitExecAddToCompileDependencies(cfg, cmd, exec_target)
        p.x("")
    end

    function m.emitExecExecutable(cfg, cmd)
        fbuild.emitStructValue("ExecExecutable", cmd.executable, false, fbuild.fmap.quote)
    end

    function m.emitExecArguments(cfg, cmd)
        fbuild.emitStructValue("ExecArguments", cmd.arguments, false, fbuild.fmap.quote)
    end

    function m.emitExecOutput(cfg, cmd)
        fbuild.emitStructValue("ExecOutput", cmd.output, false, fbuild.fmap.quote)
    end

    function m.emitExecInput(cfg, cmd)
        fbuild.emitStructValue("ExecInput", cmd.input, false, fbuild.fmap.quote)
    end

    function m.emitExecAddToCompileDependencies(cfg, cmd, exec_target)
        local prj = cfg.project or cfg
        if not cfg.project then
            p.x(".%s_%s_compile_dependencies + '%s'", prj.name, fastbuild.projectPlatform(cfg), exec_target)
        else
            for cfg in project.eachconfig(prj) do
                p.x(".%s_%s_compile_dependencies + '%s'", prj.name, fastbuild.projectPlatform(cfg), exec_target)
            end
        end
    end


---------------------------------------------------------------------------
--
-- Files
--
---------------------------------------------------------------------------

    function m.files(prj)
        local groups = m.categorizeSources(prj)
        for _, group in ipairs(groups) do
            local mapped_files = group.category.emitFiles(prj, group)
            group.category.emitLibs(prj, group, mapped_files)
        end
    end

    m.categories = { }

---
-- Include group
---

    m.categories.Include = {
        name = "Include",
        extensions = { ".h", ".hh", ".hpp", ".hxx", ".inl" },
        priority = 1,

        emitFiles = function(prj, group)
            -- m.emitFiles(prj, group, "Include", { m.generatedFile })
        end,

        emitLibs = function(prj, group)
        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "Include")
        end
    }

---
-- CustomBuild group
---
    function m.isAssemblyFile(fcfg)
        return fcfg and path.hasextension(fcfg.name, ".asm")
    end

    m.categories.CustomBuild = {
        name = "CustomBuild",
        priority = 2,

        inputField = "InputFiles",

        emitFiles = function(prj, group)
            local fileCfgFunc = {
                m.buildCommands
            }

            local fileProcFunc = {
                m.execWriteCommand,
            }

            m.emitCustomFiles(prj, group, "CustomBuild", fileCfgFunc, fileProcFunc, function(cfg, fcfg)
                return fileconfig.hasCustomBuildRule(fcfg) and not m.isAssemblyFile(fcfg)
            end)
        end,

        emitLibs = function(prj, group)

        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "CustomBuild")
        end
    }

---
-- Compile group
---

    assert(not m.elements.compile)

    m.elements.compile = function(prj, cfg, name, files)
        if prj.unity_builds then
            return {
                -- m.emitUnityFunction
                files and m.emitUnitySpecificFiles or m.emitUnityUsingDefaultFiles,
                m.emitUnityOutputPath,
                m.emitUnityPCHFile,
                m.emitUnityCompileDependency,
                m.emitUnityIsolateWritableFiles,
                m.emitUnityIsolateWritableFilesLimit,
            }
        else
            return {
            }
        end
    end

    m.categories.Compile = {
        name = "Compile",
        extensions = { ".cc", ".cpp", ".cxx", ".c", ".s", ".m", ".mm" },
        priority = 3,

        inputField = "CompilerInputFiles",

        emitFiles = function(prj, group)
            local fileCfgFunc = function(fcfg)
                if fcfg then
                    return {
                        m.clCompilePreprocessorDefinitions,
                        m.clCompileAdditionalIncludeDirectories,
                        m.generatedFile,
                        m.precompiledHeader,
                        m.unityBuildDisabled,
                        m.unityTag
                    }
                else
                    return {
                    }
                end
            end

            return m.emitFiles(prj, group, "default", { }, fileCfgFunc, function(cfg, fcfg)
                if fcfg then
                    return not fcfg.flags.ExcludeFromBuild
                else
                    return true
                end
            end)
        end,

        emitLibs = function(prj, group, mapped_files)
            local pch_files = group.pch_files

            local function addAsCompileDependency(data)
                p.x(".%s_%s_compile_dependencies + { '%s' }", data.prj.name, fastbuild.projectPlatform(data.cfg), data.name)
            end

            local function hasFlag_NoPCH(data)
                return data.files and #data.files > 0 and data.files[1].flags.NoPCH
            end

            local function addPCHSupport(prj, cfg, name)
                local files = pch_files[cfg]

                if files and #files == 1 then
                    local pch_source = fastbuild.path(cfg, prj.pchsource)
                    local pch_output = fastbuild.path(cfg, cfg.objdir .. "/" .. name .. ".pch")

                    p.x("")
                    p.x("; PrecompiledHeader settings")
                    p.x(".PCHInputFile = '%s'", pch_source)
                    p.x(".PCHOutputFile = '%s'", pch_output)
                    p.x(".PCHOptions")
                    m.element(('/Yc"%s"'):format(prj.pchheader), "PrecompiledHeader source file")
                    m.element(('/Fp"%s"'):format(pch_output), "PrecompiledHeader database")
                    p.x(".CompilerOptions")
                    m.element(('/Yu"%s"'):format(prj.pchheader), "PrecompiledHeader header file")
                    m.element(('/Fp"%s"'):format(pch_output), "PrecompiledHeader database")
                end
            end

            local function addCompilerOptions(data)
                p.x(".PCHOptions")
                m.programDatabaseFilename(data.cfg, data.prj, data.name)
                p.x(".CompilerOptions")
                m.programDatabaseFilename(data.cfg, data.prj, data.name)
            end

            local function addPCHOptions(data)
                local prj = data.prj
                local cfg = data.cfg

                if cfg.pchheader and not hasFlag_NoPCH(data) then
                    addPCHSupport(prj, cfg, data.name)
                end
            end

            local spec_files = group.spec_files
            local gen_files = group.gen_files

            local pch_compiler_object_list = {
                m.objectListUsing("config_{prj}_{platform}"),
                m.objectListPreBuildDependency(".{prj}_{platform}_compile_dependencies", true),
                m.objectListCompilerOutputPath,
                m.objectListCompilerInputFilesRoot,
                addPCHSupport
            }

            local custom_compiler_object_list = {
                m.objectListUsing("config_{prj}_{platform}"),
                m.objectListPreBuildDependency(".{prj}_{platform}_compile_dependencies", true),
                m.objectListCompilerOutputPath,
                m.objectListCompilerInputFilesRoot,
                m.objectListCompilerInputFiles,
                addPCHOptions,
                addCompilerOptions,
            }

            local default_compiler_object_list = {
                m.objectListUsing("config_{prj}_{platform}"),
                m.objectListUsing("default_{prj}_files"),
                m.objectListPreBuildDependency(".{prj}_{platform}_compile_dependencies", true),
                m.objectListPreBuildDependency(".{prj}_{platform}_prebuild_deps"),
                m.objectListCompilerOutputPath,
                m.objectListCompilerInputFilesRoot,
                addPCHOptions,
                addCompilerOptions,
            }

            for cfg in project.eachconfig(prj) do
                local lib
                local libs = { }

                local num = 0
                for content, files in pairs(mapped_files.custom[cfg]) do
                    num = num + 1

                    local func_list = table.deepcopy(custom_compiler_object_list)
                    table.insertafter(func_list, m.objectListCompilerOutputPath, m.objectListCompilerOptions(content))

                    if prj.unity_builds and #files > 0 and not files[1].flags.FBUnityBuildDisabled then
                        local unity = m.emitUnityFunction(prj, cfg, "custom" .. num, m.elements.compile, nil, files)
                        table.replace(func_list, m.objectListCompilerInputFiles, m.emitObjectList2CompilerInputUnity(unity))
                    end

                    lib = m.writeObjectList(prj, cfg, files, "custom" .. num, func_list)
                    if lib then
                        table.insert(libs, lib)
                    end
                end

                if mapped_files.default then
                    if prj.unity_builds then
                        local unity = m.emitUnityFunction(prj, cfg, "default", m.elements.compile)
                        lib = m.emitObjectList_2(prj, cfg, "default", {
                            m.emitObjectList2UsingConfig,
                            m.emitObjectList2Dependency,
                            m.emitObjectList2CompilerInputUnity(unity),
                            m.emitObjectList2CompilerOutputPath,
                            function(prj, cfg) addPCHOptions({ prj = prj, cfg = cfg, name = prj.name .. "_pch" }) end,
                            function(prj, cfg) addCompilerOptions({ prj = prj, cfg = cfg, name = prj.name .. "_pdb" }) end
                        })
                    else
                        lib = m.writeObjectList(prj, cfg, {}, "default", default_compiler_object_list)
                    end
                    if lib then
                        table.insert(libs, lib)
                    end
                end

                f.section("%s library list ", prj.name, fastbuild.projectPlatform(cfg, "-"))
                p.x(".libs_%s_%s = {", prj.name, fastbuild.projectPlatform(cfg))
                p.push()
                for _, lib in pairs(libs) do
                    p.x("'%s', ", lib)
                end

                p.pop("}")
                p.w()
            end
        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "compile")
        end
    }

---
-- None group
---

    m.categories.None = {
        name = "None",
        priority = 4,

        emitFiles = function(prj, group)
            -- m.emitFiles(prj, group, "None", { m.generatedFile })
        end,

        emitLibs = function(prj, group)
        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "None")
        end
    }

---
-- ResourceCompile group
---

    m.categories.ResourceCompile = {
        name = "ResourceCompile",
        extensions = { ".rc" },
        priority = 5,

        inputField = "CompilerInputFiles",

        emitFiles = function(prj, group)
            local fileCfgFunc = {
            }

            return m.emitFiles(prj, group, "ResourceCompile", nil, nil, function(cfg)
                return cfg.system == p.WINDOWS
            end)
        end,

        emitLibs = function(prj, group, mapped_files)
            local function emitUsingResourceCompiler(prj, cfg)
                m.emitUsing(fbuild.targetCompilerPlatformStruct(cfg, "res"))
            end

            local function emitAdditionalIncludeDirs(cfg)
                return function()
                    p.x(".CompilerOptions = ''")
                    m.clCompileAdditionalIncludeDirectories(cfg)
                    m.clCompilePreprocessorDefinitions(cfg)
                    p.push()
                    p.x("+ ' $ResCompilerOptions$'")
                    p.pop()
                end
            end

            local content = {
                emitUsingResourceCompiler,
                m.emitObjectList2UsingInputFiles(group.struct_name),
                m.emitObjectList2Dependency,
                m.emitObjectList2CompilerOutputPath,
            }

            local results = {
                function(prj, cfg, name)
                    p.x(".libs_%s_%s + { '%s' }", prj.name, fastbuild.projectPlatform(cfg), name)
                end
            }

            for cfg in project.eachconfig(prj) do
                local content_copy = table.deepcopy(content)
                table.insert(content_copy, emitAdditionalIncludeDirs(cfg))

                m.emitObjectList_2(prj, cfg, "rc", content_copy, results, { })
            end
        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "ResourceCompile")
        end
    }

---
-- Masm group
---

    function m.checkAsmCommand(fcfg)
        if fcfg and path.hasextension(fcfg.name, ".asm") then
            m.element('', "Dummy to ignore")

            -- assert(#fcfg.buildcommands == 1)
            -- local cmd = fcfg.buildcommands[1]

            -- local executable = cmd:match("^.-%.exe")
            -- cmd = cmd:sub(#executable + 1)

            -- p.x(".ExecExecutable = '$x64VSBinBasePath$\\%s'", executable)
            -- print(executable, cmd)

            -- for _, cmd in pairs() do
            -- end
            -- print(fcfg.buildcommands[1])
        end
    end

    m.categories.Masm = {
        name       = "Masm",
        extensions = ".asm",
        priority   = 7,

        inputField = "InputFiles",

        emitFiles = function(prj, group)
            local fileCfgFunc = function(fcfg)
                if fcfg then
                    return {
                        m.checkAsmCommand
                    }
                else
                    return {
                    }
                end
            end

            return m.emitFiles(prj, group, "Masm", {  }, fileCfgFunc)
        end,

        emitLibs = function(prj, group, mapped_files)

            local function scopedFunction(cfg)

                for content, files in pairs(mapped_files.custom[cfg]) do

                    local asm_object_list = {
                        m.objectListPreBuildDependency(".{prj}_{platform}_compile_dependencies", true),
                        m.objectListCompiler("$AssemblyExe$"),
                        m.objectListCompilerOutputPath,
                        m.objectListCompilerInputFilesRoot,
                        m.objectListCompilerOptions(' = \'/c /Cx /nologo /Fo"%2" "%1"\''),
                        m.objectListCompilerInputFiles
                    }

                    local function emitObjectListLib(data)
                        p.x("^libs_%s_%s + { '%s' }", data.prj.name, data.platform, data.name)
                    end

                    local lib = m.writeObjectList(prj, cfg, files, "asm", asm_object_list, { emitObjectListLib })

                end

            end

            for cfg in project.eachconfig(prj) do
                m.emitScope({
                    m.emitUsingCA(fbuild.targetCompilerPlatformStruct(cfg)),
                    scopedFunction,
                }, {}, cfg)
            end
        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "Masm")
        end,

        emitExtensionSettings = function(prj, group)
            -- p.w('<Import Project="$(VCTargetsPath)\\BuildCustomizations\\masm.props" />')
        end,

        emitExtensionTargets = function(prj, group)
            -- p.w('<Import Project="$(VCTargetsPath)\\BuildCustomizations\\masm.targets" />')
        end
    }

---
-- Image group
---
    m.categories.Image = {
        name       = "Image",
        extensions = { ".gif", ".jpg", ".jpe", ".png", ".bmp", ".dib", "*.tif", "*.wmf", "*.ras", "*.eps", "*.pcx", "*.pcd", "*.tga", "*.dds" },
        priority   = 8,

        emitFiles = function(prj, group)
            local fileCfgFunc = function(fcfg, condition)
                return {
                    m.excludedFromBuild
                }
            end
            -- m.emitFiles(prj, group, "Image", nil, fileCfgFunc)
        end,

        emitLibs = function(prj, group)
        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "Image")
        end
    }

---
-- Natvis group
---
    m.categories.Natvis = {
        name       = "Natvis",
        extensions = { ".natvis" },
        priority   = 9,

        emitFiles = function(prj, group)
            -- m.emitFiles(prj, group, "Natvis", {m.generatedFile})
        end,

        emitLibs = function(prj, group)
        end,

        emitFilter = function(prj, group)
            -- m.filterGroup(prj, group, "Natvis")
        end
    }

---
-- Categorize files into groups.
---
    function m.categorizeSources(prj)
        -- if we already did this, return the cached result.
        if prj._fastbuild_sources then
            return prj._fastbuild_sources
        end

        -- build the new group table.
        local result = {}
        local groups = {}
        prj._fastbuild_sources = result

        local tr = project.getsourcetree(prj)
        tree.traverse(tr, {
            onleaf = function(node)
                local cat = m.categorizeFile(prj, node)
                groups[cat.name] = groups[cat.name] or {
                    category = cat,
                    files = {}
                }
                table.insert(groups[cat.name].files, node)
            end
        })

        -- sort by relative-to path; otherwise VS will reorder the files
        for name, group in pairs(groups) do
            table.sort(group.files, function (a, b)
                return a.relpath < b.relpath
            end)
            table.insert(result, group)
        end

        -- sort by category priority then name; so we get stable results.
        table.sort(result, function (a, b)
            if (a.category.priority == b.category.priority) then
                return a.category.name < b.category.name
            end
            return a.category.priority < b.category.priority
        end)

        return result
    end

    function m.categorizeFile(prj, file, mapped_files)
        -- If any configuration for this file uses a custom build step,
        -- that's the category to use
        for cfg in project.eachconfig(prj) do
            local fcfg = fileconfig.getconfig(file, cfg)
            if fileconfig.hasCustomBuildRule(fcfg) and not m.isAssemblyFile(fcfg) then
                return m.categories.CustomBuild
            end
        end

        -- If there is a custom rule associated with it, use that
        local rule = p.global.getRuleForFile(file.name, prj.rules)
        if rule then
            return {
                name      = rule.name,
                priority  = 100,
                rule      = rule,
                emitFiles = function(prj, group)
                    m.emitRuleFiles(prj, group)
                end,
                emitFilter = function(prj, group)
                    m.filterGroup(prj, group, group.category.name)
                end
            }
        end

        -- Otherwise use the file extension to deduce a category
        for _, cat in pairs(m.categories) do
            if cat.extensions and path.hasextension(file.name, cat.extensions) then
                return cat
            end
        end

        return m.categories.None
    end

    function m.emitCustomFiles(prj, group, tag, fileCfgFunc, fileProcFunc, checkFunc)
        local files = group.files
        local category = group.category

        local processed_files = { }
        local function sort_asc(f1, f2) return f1.name < f2.name end

        if files and #files > 0 then

            -- For each file
            for _, file in pairs(files) do
                local rel = fastbuild.path(prj, file.abspath)

                -- In each configuration
                for cfg in project.eachconfig(prj) do
                    local buildcfg = cfg.buildcfg
                    local proc_cfg_files = processed_files[cfg.buildcfg] or { default = { } }

                    -- Get the file config
                    local fcfg = fileconfig.getconfig(file, cfg)
                    if not checkFunc or checkFunc(cfg, fcfg) then

                        -- Capture any custom output
                        local contents = p.capture(function()
                            p.callArray(fileCfgFunc, fcfg)
                        end)

                        -- We got some custom putput
                        if #contents > 0 then
                            proc_cfg_files[contents] = proc_cfg_files[contents] or { }
                            table.insert(proc_cfg_files[contents], file)
                        else
                            table.insert(proc_cfg_files.default, file)
                        end

                        -- Save the list
                        processed_files[cfg.buildcfg] = proc_cfg_files

                    end
                end

            end


            -- In each configuration
            for cfg in project.eachconfig(prj) do
                local proc_files = processed_files[cfg.buildcfg]

                local sorted = { }
                for cont, files in pairs(proc_files) do
                    table.insert(sorted, { cont, files })
                end

                table.sort(sorted, function(e1, e2)
                    return e1[1] < e2[1]
                end)

                for _, entry in pairs(sorted) do
                    p.callArray(fileProcFunc, prj, cfg, entry[2], entry[1])
                end
            end

        end
    end


    function m.emitFiles(prj, group, tag, prjFunc, fileCfgFunc, checkFunc)
        local files = group.files
        local category = group.category

        local file_map = {
            default = false,
            custom = { },
            pch = { },
        }

        local pch_files = { }

        local function checkEachFile(file)
            local is_default = true
            for cfg in project.eachconfig(prj) do
                local fcfg = fileconfig.getconfig(file, cfg)

                    local pch_files_ = file_map.pch[cfg] or { }
                    local custom_files = file_map.custom[cfg] or { }

                    local contents = p.capture(function ()
                        p.pop()
                        if not checkFunc or checkFunc(cfg, fcfg) then
                            p.callArray(fileCfgFunc, fcfg)
                        end
                        p.push()
                    end)

                    if fcfg and fcfg.pchsource then
                        assert(not pch_files[cfg])
                        pch_files[cfg] = { { fcfg, contents } }
                        is_default = false

                    elseif #contents > 0 then
                        contents = "\n" .. contents

                        custom_files[contents] = custom_files[contents] or { }
                        table.insert(custom_files[contents], fcfg)

                        is_default = false
                    end

                    if is_default and checkFunc then
                        is_default = checkFunc(cfg, fcfg)
                    end

                    file_map.pch[cfg] = pch_files_
                    file_map.custom[cfg] = custom_files
            end
            return is_default
        end

        local function emitInnerList(files)
            m.emitListItems(files, function(file)
                file_map.default = true
                return fastbuild.path(prj, file.abspath)
            end, checkEachFile)
        end

        local function emitInnerStruct(files)
            p.callArray(prjFunc, prj, files)

            m.emitList(category.inputField, { emitInnerList }, nil, files)
        end

        if files and #files > 0 then

            local struct_name = ("%s_%s_files"):format(tag, prj.name)
            m.emitStruct(struct_name, { emitInnerStruct }, nil, files)

            prj.default_files = files
            group.struct_name = struct_name
        end

        group.pch_files = pch_files

        return file_map
    end

---------------------------------------------------------------------------
--
-- Handlers for emiting object lists
--
---------------------------------------------------------------------------

    function m.writeObjectList(prj, cfg, files, name, innerFuncs, endFuncs)
        local prjplatform = fastbuild.projectPlatform(cfg)
        local name = ("objects_%s_%s_%s"):format(prj.name, prjplatform, name)

        local data = {
            prj = prj,
            cfg = cfg,
            files = files,

            platform = prjplatform,
            name = name
        }

        if files then
            m.emitFunction("ObjectList", name, innerFuncs, endFuncs, data)
            return name
        end
    end

    local function objectListReplaceTokens(str, data)
        if data then
            str = str:gsub("%{(.-)%}", function(element)
                return data[element].name or data[element] or ("{" .. element .. "}")
            end)
        end
        return str
    end

    function m.objectListUsing(struct_name)
        return function(data)
            p.x("Using( .%s )", objectListReplaceTokens(struct_name, data))
        end
    end

    function m.objectListPreBuildDependency(dependency, first)
        return function(data)
            p.x(".PreBuildDependencies %s %s", (first and "=" or "+"), objectListReplaceTokens(dependency, data))
        end
    end

    function m.objectListCompiler(compiler)
        return function(data)
            p.x(".Compiler = '%s'", compiler)
        end
    end

    function m.objectListCompilerOutputPath(data)
        local prj = data.prj
        local cfg = data.cfg

        p.x(".CompilerOutputPath = '%s'", fastbuild.path(prj, cfg.objdir))
    end

    function m.objectListCompilerOptions(options)
        return function(data)
            p.x(".CompilerOptions %s", options)
        end
    end

    function m.objectListDisableDistribution(data)
        p.x(".AllowDistribution = false")
    end

    function m.objectListDisableCaching(data)
        p.x(".AllowCaching = false")
    end

    function m.objectListCompilerInputFilesRoot(data)
        if data and data.prj then
            local prj = data.prj
            local inputs_path = fastbuild.projectLocation(prj)
            local inputs_base_path = path.getdirectory(inputs_path)
            local inputs_root = path.translate(inputs_path)

            assert(not prj.inputs_root or prj.inputs_root == inputs_root)
            prj.inputs_root = inputs_root

            p.x(".CompilerInputFilesRoot = '%s'", inputs_root)
            p.x(".CompilerInputFilesBasePath = '%s'", inputs_base_path)
        end
    end

    function m.objectListCompilerInputFiles(data)
        local prj = data.prj

        m.emitList("CompilerInputFiles", { m.emitListItems }, nil, data.files, function(file)
            return fastbuild.path(prj, file.abspath)
        end)
    end

---------------------------------------------------------------------------
--
-- Handlers for emiting object list calls
--
---------------------------------------------------------------------------

    function m.emitObjectList_2(prj, cfg, postfix, inner, after, ...)
        local platform = fastbuild.projectPlatform(cfg)
        local name = fastbuild.targetName(cfg, "objects", postfix)

        m.emitFunction("ObjectList", name, inner, after, prj, cfg, name, ...)
        return name
    end

    function m.emitObjectList2Dependency(prj, cfg, name, files)
        p.x(".PreBuildDependencies = .%s", fastbuild.targetName(cfg, nil, "compile_dependencies"))
        if not files then
            p.x(".PreBuildDependencies + .%s", fastbuild.targetName(cfg, nil, "prebuild_deps"))
        end
    end

    function m.emitObjectList2UsingConfig(prj, cfg)
        m.emitUsing(fastbuild.targetName(cfg, "config"))
    end

    function m.emitObjectList2UsingInputFiles(struct)
        return function()
            m.emitUsing(struct)
        end
    end

    function m.emitObjectList2CompilerInputUnity(unity)
        return function()
            p.x(".CompilerInputUnity = '%s'", unity)
        end
    end

    function m.emitObjectList2CompilerOutputPath(prj, cfg)
        p.x(".CompilerOutputPath = '%s'", fastbuild.path(prj, cfg.objdir))
    end

---------------------------------------------------------------------------
--
-- Handlers for emiting unity calls
--
---------------------------------------------------------------------------

    function m.emitUnityFunction(prj, cfg, postfix, inner, after, ...)
        local platform = fastbuild.projectPlatform(cfg)
        local name = fastbuild.targetName(cfg, "unity", postfix)

        m.emitFunction("Unity", name, inner, after, prj, cfg, name, ...)
        return name
    end

    function m.emitUnityUsingDefaultFiles(prj, cfg)
        m.emitUsing("default_" .. prj.name .. "_files")
        p.x(".UnityNumFiles = %s", tostring(math.floor(#prj.default_files / 45 + 1)))
        p.x(".UnityInputFiles = %s", ".CompilerInputFiles")
    end

    function m.emitUnitySpecificFiles(prj, cfg, name, files)
        p.x(".UnityOutputPattern = '%s*.cpp'", name)
        p.x(".UnityNumFiles = %s", tostring(math.floor(#files / 40 + 1)))
        m.emitList("UnityInputFiles", { m.emitListItems }, nil, files, function(file)
            return fastbuild.path(prj, file.abspath)
        end)
    end

    function m.emitUnityCompileDependency(prj, cfg)
        p.x(".PreBuildDependencies = .%s", fastbuild.targetName(cfg, nil, "compile_dependencies"))
    end

    function m.emitUnityOutputPath(prj, cfg)
        p.x(".UnityOutputPath = '%s\\fb_unity'", fastbuild.path(cfg, cfg.objdir))
    end

    function m.emitUnityIsolateWritableFiles(prj, cfg)
        if prj.fbunity and prj.fbunity.isolate_writable_files then
            fbuild.emitStructValue("UnityInputIsolateWritableFiles", true);
        end
    end

    function m.emitUnityIsolateWritableFilesLimit(prj, cfg)
        if prj.fbunity and prj.fbunity.isolate_writable_files and prj.fbunity.isolate_writable_files_limit then
            fbuild.emitStructValue("UnityInputIsolateWritableFilesLimit", prj.fbunity.isolate_writable_files_limit);
        end
    end

    function m.emitUnityPCHFile(prj, cfg)
        if cfg.pchheader and not cfg.flags.NoPCH then
            p.x(".UnityPCH = '%s'", cfg.pchheader)
        end
    end

---------------------------------------------------------------------------
--
-- Writing functions, structs and scopes
--
---------------------------------------------------------------------------

    function m.emitUsing(value, ...)
        p.x("Using( .%s )", value:format(...))
    end

    function m.emitFunction(name, alias, inner, after, ...)
        if alias and #alias > 0 then
            p.x("%s( '%s' )", name, alias)
        else
            p.x("%s()", name)
        end
        m.emitScope(inner, after, ...)
    end

    function m.emitList(name, inner, after, ...)
        p.x(".%s = ", name)
        m.emitScope(inner, after, ...)
    end

    function m.emitListItems(items, fmap, check)
        if not fmap then
            fmap = function(e) return e end
        end

        for _, item in pairs(items) do
            if not check or check(item) then
                p.x("'%s', ", fmap(item))
            end
        end
    end

    function m.emitForLoop(arg, array, inner, after, ...)
        p.x("ForEach( .%s in .%s ) ", arg, array)
        m.emitScope(inner, after, arg, ...)
    end

    function m.emitScope(inner, after, ...)
        p.push("{")
        p.callArray(inner, ...)
        p.pop("}")
        p.callArray(after, ...)
        p.x("")
    end

    function m.emitStruct(name, inner, after, ...)
        p.x(".%s = ", name)
        p.push("[")
        p.callArray(inner, ...)
        p.pop("]")
        p.callArray(after, ...)
        p.x("")
    end

---------------------------------------------------------------------------
--
-- Writing functions, structs and scopes (callArrayVersions)
--
---------------------------------------------------------------------------

    function m.emitUsingCA(value, ...)
        value = value:format(...)
        return function(...)
            m.emitUsing(value, ...)
        end
    end

    function m.emitFunctionCA(name, alias, inner, after, ...)
        local args = { ... }
        return function(...)
            m.emitFunction(name, alias, inner, after, ..., unpack(args))
        end
    end

    function m.emitForLoopCA(arg, array, inner, after, ...)
        local args = { ... }
        return function(...)
            m.emitForLoop(arg, array, inner, after, ..., unpack(args))
        end
    end

---------------------------------------------------------------------------
--
-- Project binary representations
--
---------------------------------------------------------------------------

    function m.projectBinary(prj)
        local kind_map = { ConsoleApp = m.projectExecutable, WindowedApp = m.projectExecutable, StaticLib = m.projectLibrary, SharedLib = m.projectDLL }

        f.section("Binaries")
        for cfg in project.eachconfig(prj) do
            local func = kind_map[cfg.kind]

            if func then
                func(prj, cfg)
            else
                prj.fbuild.notarget = true
            end
        end
    end

    function m.projectDependencies(prj, cfg)
        local use_dep_inputs = (cfg.usedependencyinputs and cfg.usedependencyinputs:lower() == "yes")
        local refs = project.getdependencies(prj, 'linkOnly')
        local libs = { }
        if #refs > 0 then
            for _, ref in ipairs(refs) do

                local linktarget = project.getconfig(ref, cfg.buildcfg, cfg.platform or "Win32").buildtarget

                if use_dep_inputs and ref.kind == p.SHAREDLIB then

                    table.insert(libs, path.translate(linktarget.directory .. "/") .. linktarget.name)

                elseif not use_dep_inputs and (ref.kind ~= p.CONSOLEAPP and ref.kind ~= p.WINDOWEDAPP) then

                    table.insert(libs, path.translate(linktarget.directory .. "/") .. linktarget.name)

                end

            end
        end
        return libs
    end

    function m.projectLinkDependencyInputs(prj, cfg)
        local is_dll = cfg.kind == p.SHAREDLIB
        return cfg.usedependencyinputs and cfg.usedependencyinputs:lower() == "yes" and config.canLinkIncremental(cfg) and is_dll
    end

    function m.projectDependencyTargets(prj, cfg)
        local use_dep_inputs = m.projectLinkDependencyInputs(prj, cfg)
        local refs = project.getdependencies(prj, 'linkOnly')
        local libs = { }
        if #refs > 0 then
            for _, ref in ipairs(refs) do

                local ref_cfg = project.getconfig(ref, cfg.buildcfg, cfg.platform or "Win32")
                if ref_cfg then

                    local linktarget = ref_cfg.buildtarget

                    if use_dep_inputs and ref.kind == p.SHAREDLIB then

                        table.insert(libs, fastbuild.projectTargetname(ref, cfg)) -- path.translate(linktarget.directory .. "/") .. linktarget.name)

                    elseif not use_dep_inputs and (ref.kind ~= p.CONSOLEAPP and ref.kind ~= p.WINDOWEDAPP) then

                        table.insert(libs, fastbuild.projectTargetname(ref, cfg)) -- path.translate(linktarget.directory .. "/") .. linktarget.name)

                    end

                end
            end
        end
        return libs
    end

    function m.projectDependencyInputs(prj, cfg)
        if not m.projectLinkDependencyInputs(prj, cfg) then
            return { }
        end

        local refs = project.getdependencies(prj, 'linkOnly')
        local libs = { }
        if #refs > 0 then
            for _, ref in ipairs(refs) do

                if ref.kind == p.STATICLIB then

                    table.insert(libs, (".libs_%s_%s"):format(ref.name, fastbuild.projectPlatform(cfg)))

                end

            end
        end

        return libs
    end

    function m.projectExecutable(prj, cfg)
        local outdir = path.translate(cfg.buildtarget.directory .. "/")
        local outname = cfg.buildtarget.name

        local dep_libs = m.projectDependencyTargets(prj, cfg)
        local subsystem = cfg.kind == p.CONSOLEAPP and "CONSOLE" or "WINDOWS"

        p.x("Executable('%s')", fastbuild.projectTargetname(prj, cfg))
        p.push("{")
        p.x("Using( .config_%s_%s )", prj.name, fastbuild.projectPlatform(cfg))
        p.x(".LinkerOptions + ' /SUBSYSTEM:%s'", subsystem)

        p.push(".Libraries = .libs_%s_%s", prj.name, fastbuild.projectPlatform(cfg))
        for _, inputs_struct in pairs(m.projectDependencyInputs(prj, cfg)) do
            p.x("+ %s", inputs_struct)
        end
        for _, lib in pairs(dep_libs) do
            p.x('+ \'%s\'', lib)
        end
        p.pop()

        f.struct_pair("LinkerOutput", "%s%s", outdir, outname)
        p.pop("}")
        p.x(".AllTargets_%s + '%s'", fastbuild.projectPlatform(cfg), fastbuild.projectTargetname(prj, cfg))
        p.w()
    end

    function m.projectDLL(prj, cfg)
        local outdir = path.translate(cfg.buildtarget.directory .. "/")
        local outname = cfg.buildtarget.name

        local dep_libs = m.projectDependencyTargets(prj, cfg)

        p.x("DLL('%s')", fastbuild.projectTargetname(prj, cfg))
        p.push("{")
        p.x("Using( .config_%s_%s )", prj.name, fastbuild.projectPlatform(cfg))
        p.x(".LinkerOptions + ' /DLL'")
        p.push()
        p.x("+ ' /SUBSYSTEM:WINDOWS'")
        p.x("+ ' /IMPLIB:\"%s\"'", cfg.linktarget.abspath)
        p.pop()

        p.push(".Libraries = .libs_%s_%s", prj.name, fastbuild.projectPlatform(cfg))
        for _, inputs_struct in pairs(m.projectDependencyInputs(prj, cfg)) do
            p.x("+ %s", inputs_struct)
        end
        for _, lib in pairs(dep_libs) do
            p.x('+ \'%s\'', lib)
        end
        p.pop()

        p.x(".LinkerLinkObjects = %s", tostring(m.projectLinkDependencyInputs(prj, cfg) == true))
        f.struct_pair("LinkerOutput", "%s%s", outdir, outname)
        p.pop("}")
        p.w()
    end

    function m.projectLibrary(prj, cfg)
        p.x("Library('%s')", fastbuild.projectTargetname(prj, cfg))
        p.push("{")
        p.x("Using( .config_%s_%s )", prj.name, fastbuild.projectPlatform(cfg))

        f.struct_pair("CompilerOutputPath", path.translate(cfg.objdir))
        p.x(".LibrarianAdditionalInputs = .libs_%s_%s", prj.name, fastbuild.projectPlatform(cfg))
        f.struct_pair("LibrarianOutput", "%s", cfg.linktarget.abspath)
        p.pop("}")
        p.w()
    end

---------------------------------------------------------------------------
--
-- Visual studio project support
--
---------------------------------------------------------------------------


    m.elements.vstudio = function(prj)
        return {
            m.projectVStudioConfigs,
            m.projectVStudioFilters,
            m.projectVStudioBegin,
            m.projectVStudioBuildCommands,
            m.projectVStudioFiles,
            m.projectVStudioEnd,
        }
    end

    function m.projectVisualStudio(prj)
        p.x("")
        f.section("Visual Studio project")
        p.callArray(m.elements.vstudio, prj)
    end

    function m.projectVStudioConfig(prj, cfg)
        p.x("\n// VisualStudio Config: %s", fbuild.projectPlatform(cfg, "|"))
        p.push(".%s_%s_SolutionConfig = [", prj.name, fbuild.projectPlatform(cfg))
        p.x(".Platform = '%s'", cfg.platform or "Win32")
        p.x(".Config = '%s'", cfg.buildcfg)
        if not prj.fbuild.notarget then
            p.x(".Target = '%s'", fbuild.projectTargetname(prj, cfg))
            p.x(".Output = '%s'", path.translate(cfg.buildtarget.abspath))

            -- local out_dir =
            p.x(".OutputDirectory = '%s'", path.translate(cfg.buildtarget.directory))
            p.x(".LocalDebuggerWorkingDirectory = '^$(OutDir)'")
            p.push(".AdditionalOptions = ''")
            p.callArray({ m.cppDialect }, cfg)
            p.pop()
        end
        p.pop("]")
        p.x(".%sProjectConfigs + .%s_%s_SolutionConfig\n", prj.name, prj.name, fastbuild.projectPlatform(cfg))
    end

    function m.projectVStudioConfigs(prj)
        p.x(".%sProjectConfigs = { }", prj.name)

        for cfg in project.eachconfig(prj) do
            m.projectVStudioConfig(prj, cfg)
        end

        -- Create mocks for configmaps
        for _, platform in ipairs(prj.platforms) do
            for _, mapping in ipairs(prj.configmap) do

                for name, configs in pairs(mapping) do
                    local config = project.getconfig(prj, configs[1], platform)
                    assert(config ~= nil, ("Invalid comfig mapping for '%s'"):format(name))

                    m.projectVStudioConfig(prj, { project = prj, buildcfg = name, platform = platform, buildtarget = config.buildtarget })
                end

            end
        end

    end

    function m.projectVStudioFilters(prj)

    end

    function m.projectVStudioBegin(prj)
        p.x("VCXProject( '%s' )", fbuild._targetName(prj, nil, "vcxproj"))
        p.push("{")
        p.x(".ProjectOutput = '%s\\%s.vcxproj'", fastbuild.path(prj, prj.location), prj.filename)
        p.x(".ProjectConfigs = .%sProjectConfigs", prj.name)
    end

    function m.projectVStudioBuildCommands(prj)
        p.x("")
        p.x(".ProjectBuildCommand = 'cd \"^$(SolutionDir)\" &amp; fbuild -config %s.wks.bff -ide -monitor -dist -cache %s-^$(Configuration)-^$(Platform)'", prj.workspace.filename, prj.name)
        p.x(".ProjectRebuildCommand = 'cd \"^$(SolutionDir)\" &amp; fbuild -config %s.wks.bff -ide -monitor -dist -cache -clean %s-^$(Configuration)-^$(Platform)'", prj.workspace.filename, prj.name)
        p.x(".ProjectCleanCommand = 'cd \"^$(SolutionDir)\" &amp; fbuild -config %s.wks.bff -ide -monitor -dist -cache -clean'", prj.workspace.filename)
    end

    function m.projectVStudioFiles(prj)
        p.x("")
        local project_location = fastbuild.projectLocation(prj)
        p.x(".ProjectBasePath = '%s'", path.translate(path.getdirectory(project_location )))

        p.push(".ProjectInputPaths = {")
        p.x("'%s', ", project_location)
        p.pop("}")
    end

    function m.projectVStudioEnd(prj)
        p.x(".PlatformToolset = %s", fbuild.fmap.quote(fbuild.vstudioProjectToolset(prj)))
        p.pop("}")
    end

---------------------------------------------------------------------------
--
-- Handlers for individual function elements
--
---------------------------------------------------------------------------

    ---
    -- Custom build commands
    ---
    function m.buildCommands(fcfg)
        local prj = fcfg.project
        local cfg = fcfg.config

        if fcfg.buildcommands and fcfg.buildcommands[1] and fcfg.buildcommands[1].message then
            local cmd = fcfg.buildcommands[1]
            local exec = path.getbasename(cmd.executable)
            local rel = fastbuild.path(prj, fcfg.abspath)

            local exec_target = ("%s_%s_%s_%s"):format(prj.name, fastbuild.projectPlatform(cfg), exec, fcfg.basename)

            p.x("Exec( '%s' )", exec_target)
            p.push("{")
            p.x(".ExecExecutable = '%s'", cmd.executable)
            p.x(".ExecInput = '%s'", fastbuild.path(prj, fcfg.abspath))
            p.x(".ExecOutput = '%s'", fastbuild.path(prj, cmd.output))
            p.x(".ExecArguments = ''")
            for _, arg in pairs(cmd.arguments) do
                p.x(".ExecArguments + ' %s'", arg)
            end
            p.x(".PreBuildDependencies = .%s_%s_prebuild_deps", prj.name, fastbuild.projectPlatform(cfg))
            p.pop("}")

            p.x(".%s_%s_compile_dependencies + '%s'", prj.name, fastbuild.projectPlatform(cfg), exec_target)
        end
    end

    function m.execWriteCommand(prj, cfg, files, cont)
        if #files > 0 and cont ~= 'default' then
            p.x("%s", cont)
            p.x("")
        end
    end

---------------------------------------------------------------------------
--
-- Handlers for individual project elements
--
---------------------------------------------------------------------------

    function m.additionalDependencies(cfg, explicit)
        local links

        -- check to see if this project uses an external toolset. If so, let the
        -- toolset define the format of the links
        local toolset = config.toolset(cfg)
        if toolset then
            links = toolset.getlinks(cfg, true)
        else
            links = fastbuild.getLinks(cfg, false)
        end

        if #links > 0 then
            for _, link in pairs(links) do
                m.element(('"%s"'):format(link), "Additional libray: %s", link)
            end
        end
    end

    function m.runtimeTypeInfo(cfg)
        if cfg.rtti == p.OFF and ((not cfg.clr) or cfg.clr == p.OFF) then
            m.element("/GR-", "Runtime Type Information: Disabled")
        elseif cfg.rtti == p.ON then
            m.element("/GR", "Runtime Type Information: Enabled")
        end
    end

    function m.additionalLibraryDirectories(cfg)
        if #cfg.libdirs > 0 then
            local libdirs = fastbuild.path(cfg, cfg.libdirs)
            for _, dir in pairs(libdirs) do
                m.element(('/LIBPATH:"%s"'):format(dir), "Library path: %s", dir)
            end
        end
    end

    function m.excludedFromBuild(filecfg, condition)
        if not filecfg or filecfg.flags.ExcludeFromBuild then
            m.element("ExcludedFromBuild", condition, "true")
        end
    end

    function m.generatedFile(fcfg)
        if fcfg and fcfg.generated then
            m.element("", "Generated file flag")
        end
    end

    function m.entryPointSymbol(cfg)
        if cfg.entrypoint and #cfg.entrypoint > 0 then -- #todo maybe check if this a console or windowed app?
            m.element(('/ENTRY:"%s"'):format(cfg.entrypoint), "Entry point for the application to be used: %s", cfg.entrypoint)
        end
    end

    function m.projectAliases(prj)
        for _, platform in ipairs(prj.platforms) do
            for _, mapping in ipairs(prj.configmap) do

                for name, configs in pairs(mapping) do
                    local config = project.getconfig(prj, configs[1], platform)
                    assert(config ~= nil, ("Invalid comfig mapping for '%s'"):format(name))

                    fbuild.emitAlias(fbuild.projectTargetname(prj, { project = prj, buildcfg = name, platform = platform }), {
                        fbuild.fmap.quote(fbuild.projectTargetname(prj, config))
                    })
                end

            end
        end
    end

