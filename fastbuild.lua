--
-- actions/fastbuild/fastbuild.lua
-- Extend the existing exporters with support for FASTBuild
-- Copyright (c) 2017-2017 Daniel Penkała
--

    local p = premake

    -- initialize module.
    p.modules.fastbuild = p.modules.fastbuild or {}
    p.modules.fastbuild._VERSION = p._VERSION
    p.fastbuild = p.modules.fastbuild

    -- load actions.
    require "cfg_premake/fastbuild/fastbuild_action"
    require "cfg_premake/fastbuild/fastbuild_utils"
    require "cfg_premake/fastbuild/fastbuild_dependency_resolver"
    require "cfg_premake/fastbuild/fastbuild_platforms"
    require "cfg_premake/fastbuild/fastbuild_toolset"
    require "cfg_premake/fastbuild/fastbuild_solution"
    require "cfg_premake/fastbuild/fastbuild_project"
    require "cfg_premake/fastbuild/toolsets/fastbuild_msc"
    require "cfg_premake/fastbuild/toolsets/fastbuild_clang"
