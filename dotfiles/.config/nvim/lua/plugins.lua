-- Plugin management via vim.pack (Neovim 0.12+)
-- Full GitHub URL required — vim.pack does NOT expand short "user/repo" paths.
-- vim.pack.add() is synchronous on first install, so each plugin is safe to
-- require()/setup() immediately after the add() call below.

-- Build hooks. Registered before vim.pack.add() so they also fire on the very
-- first install. telescope-fzf-native ships a C sorter that must be compiled
-- (needs `make` + a C compiler on PATH).
vim.api.nvim_create_autocmd("PackChanged", {
    callback = function(ev)
        if ev.data.spec.name == "telescope-fzf-native.nvim"
            and (ev.data.kind == "install" or ev.data.kind == "update") then
            vim.system({ "make" }, { cwd = ev.data.path }):wait()
        end
    end,
})

vim.pack.add({
    -- Colorscheme
    { src = "https://github.com/navarasu/onedark.nvim" },

    -- LSP defaults + Treesitter
    { src = "https://github.com/neovim/nvim-lspconfig" },
    { src = "https://github.com/nvim-treesitter/nvim-treesitter", version = "main" },

    -- Fuzzy finder (plenary = shared lib, fzf-native = compiled sorter)
    { src = "https://github.com/nvim-lua/plenary.nvim" },
    { src = "https://github.com/nvim-telescope/telescope.nvim" },
    { src = "https://github.com/nvim-telescope/telescope-fzf-native.nvim" },

    -- Editing / UI quality-of-life
    { src = "https://github.com/lewis6991/gitsigns.nvim" },
    { src = "https://github.com/nvim-lualine/lualine.nvim" },
    { src = "https://github.com/folke/which-key.nvim" },
    { src = "https://github.com/windwp/nvim-autopairs" },
    { src = "https://github.com/nvim-tree/nvim-web-devicons" }, -- icons; needs a Nerd Font
})

-- ---------------------------------------------------------------------------
-- Colorscheme
-- ---------------------------------------------------------------------------
require("onedark").setup({
    style = "dark",         -- "dark" | "darker" | "cool" | "deep" | "warm" | "warmer" | "light"
    transparent = false,
    term_colors = true,
    code_style = {
        comments = "italic",
        keywords = "italic",
    },
})
vim.cmd.colorscheme("onedark")

-- ---------------------------------------------------------------------------
-- Treesitter: parsers for the languages this config is used with day to day.
-- Requires a C compiler (cc/gcc) on PATH to build parsers on first install.
-- ---------------------------------------------------------------------------
local ts_langs = { "lua", "python", "bash", "vim", "vimdoc", "query", "markdown", "markdown_inline" }
require("nvim-treesitter").install(ts_langs)

vim.api.nvim_create_autocmd("FileType", {
    pattern = ts_langs,
    callback = function()
        vim.treesitter.start()
        vim.bo.indentexpr = "v:lua.vim.treesitter.indentexpr()"
    end,
})

-- ---------------------------------------------------------------------------
-- Everything below is interactive editor UX — pointless (and noisy) when
-- Neovim is running as git's difftool / mergetool over throwaway scratch
-- buffers, so bail out early there, exactly like lua/lsp.lua does.
-- ---------------------------------------------------------------------------
if require("diff").session then
    return
end

local function nmap(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { silent = true, desc = desc })
end

-- Telescope — fuzzy picker over files, live grep, buffers, LSP, diagnostics…
require("telescope").setup({
    defaults = {
        layout_strategy = "flex",
        sorting_strategy = "ascending",
        layout_config = { prompt_position = "top" },
    },
    pickers = {
        find_files = { hidden = true },
    },
})
pcall(require("telescope").load_extension, "fzf") -- native sorter; no-op if build failed

local pick = require("telescope.builtin")
nmap("<leader>ff", pick.find_files, "Find files")
nmap("<leader>fg", pick.live_grep, "Live grep")
nmap("<leader>fb", pick.buffers, "Find buffers")
nmap("<leader>fh", pick.help_tags, "Find help tags")
nmap("<leader>fd", pick.diagnostics, "Find diagnostics")
nmap("<leader>fr", pick.resume, "Resume last picker")
nmap("<leader>fw", pick.grep_string, "Grep word under cursor")
nmap("<leader>fo", pick.oldfiles, "Find recent files")
nmap("<leader><space>", pick.find_files, "Find files")

-- Gitsigns — sign-column hunks plus staging / navigation from the buffer.
require("gitsigns").setup({
    on_attach = function(bufnr)
        local gs = require("gitsigns")
        local function gmap(lhs, rhs, desc)
            vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
        end
        gmap("]h", function() gs.nav_hunk("next") end, "Next git hunk")
        gmap("[h", function() gs.nav_hunk("prev") end, "Previous git hunk")
        gmap("<leader>hs", gs.stage_hunk, "Stage hunk")
        gmap("<leader>hr", gs.reset_hunk, "Reset hunk")
        gmap("<leader>hu", gs.undo_stage_hunk, "Undo stage hunk")
        gmap("<leader>hp", gs.preview_hunk, "Preview hunk")
        gmap("<leader>hb", function() gs.blame_line({ full = true }) end, "Blame line")
        gmap("<leader>hd", gs.diffthis, "Diff this file against index")
    end,
})

-- Lualine — statusline. onedark ships a matching theme.
require("lualine").setup({
    options = {
        theme = "onedark",
        component_separators = "|",
        section_separators = "",
        globalstatus = true,
    },
})

-- which-key — popup listing the keys that can follow a prefix.
local wk = require("which-key")
wk.setup({})
wk.add({
    { "<leader>f", group = "find (telescope)" },
    { "<leader>h", group = "git hunks" },
    { "<leader>c", group = "code" },
})

-- nvim-autopairs — insert the closing bracket / quote automatically.
require("nvim-autopairs").setup({ check_ts = true })
