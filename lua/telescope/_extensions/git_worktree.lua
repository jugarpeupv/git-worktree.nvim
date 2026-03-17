local strings = require('plenary.strings')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local actions = require('telescope.actions')
local utils = require('telescope.utils')
local action_set = require('telescope.actions.set')
local action_state = require('telescope.actions.state')
local conf = require('telescope.config').values
local git_worktree = require('git-worktree')
local Config = require('git-worktree.config')
local Git = require('git-worktree.git')
local Log = require('git-worktree.logger')
local Job = require('plenary.job')

local function starts_with(str, prefix2)
    return string.sub(str, 1, string.len(prefix2)) == prefix2
end

local function removePrefix(s, prefix2)
    return string.gsub(s, '^' .. prefix2, '')
end

local force_next_deletion = false

-- Get all git tags
-- @return table: list of tag names
local get_git_tags = function()
    local tag_job = Job:new {
        command = 'git',
        args = { 'tag', '--sort=-version:refname' },
    }
    local ok, tags = pcall(function()
        return tag_job:sync()
    end)
    if not ok then
        return {}
    end
    return tags or {}
end

-- Check if a reference is a tag
-- @param ref string: the reference to check
-- @return boolean: true if it's a tag
local is_tag = function(ref)
    local tags = get_git_tags()
    for _, tag in ipairs(tags) do
        if tag == ref then
            return true
        end
    end
    return false
end

-- Get the path of the selected worktree
-- @param prompt_bufnr number: the prompt buffer number
-- @return string: the path of the selected worktree
local get_worktree_path = function(prompt_bufnr)
    local selection = action_state.get_selected_entry(prompt_bufnr)
    if selection == nil then
        return
    end
    return selection.path
end

-- Switch to the selected worktree
-- @param prompt_bufnr number: the prompt buffer number
-- @return nil
local switch_worktree = function(prompt_bufnr)
    local worktree_path = get_worktree_path(prompt_bufnr)
    if worktree_path == nil then
        vim.print('No worktree selected')
        return
    end
    actions.close(prompt_bufnr)
    git_worktree.switch_worktree(worktree_path)
end

-- Toggle the forced deletion of the next worktree
-- @return nil
local toggle_forced_deletion = function()
    -- redraw otherwise the message is not displayed when in insert mode
    if force_next_deletion then
        vim.print('The next deletion will not be forced')
        vim.fn.execute('redraw')
    else
        vim.print('The next deletion will be forced')
        vim.fn.execute('redraw')
        force_next_deletion = true
    end
end

-- Confirm the deletion of a worktree
-- @param forcing boolean: whether the deletion is forced
-- @return boolean: whether the deletion is confirmed
local confirm_worktree_deletion = function(forcing)
    if not Config.confirm_telescope_deletions then
        return true
    end

    local confirmed
    if forcing then
        confirmed = vim.fn.input('Force deletion of worktree? [y/n]: ')
    else
        confirmed = vim.fn.input('Delete worktree? [y/n]: ')
    end

    if string.sub(string.lower(confirmed), 0, 1) == 'y' then
        return true
    end

    print("Didn't delete worktree")
    return false
end

-- Confirm the deletion of a worktree
-- @return boolean: whether the deletion is confirmed
local confirm_branch_deletion = function()
    -- local confirmed = vim.fn.input('Worktree deleted, now force deletion of branch? [y/n]: ')
    --
    -- if string.sub(string.lower(confirmed), 0, 1) == 'y' then
    --     return true
    -- end
    --
    -- print("Didn't delete branch")
    return false
end

-- Handler for successful deletion
-- @return nil
local delete_success_handler = function(opts)
    opts = opts or {}
    force_next_deletion = false
    if opts.branch ~= nil and opts.branch ~= 'HEAD' and confirm_branch_deletion() then
        local delete_branch_job = Git.delete_branch_job(opts.branch)
        if delete_branch_job ~= nil then
            delete_branch_job:after_success(vim.schedule_wrap(function()
                print('Branch deleted')
            end))
            delete_branch_job:start()
        end
    end
end

-- Handler for failed deletion
-- @return nil
local delete_failure_handler = function()
    print('Deletion failed, use <C-f> to force the next deletion')
end

-- Delete the selected worktree
-- @param prompt_bufnr number: the prompt buffer number
-- @return nil
local delete_worktree = function(prompt_bufnr)
    -- TODO: confirm_deletion(forcing)
    if not confirm_worktree_deletion() then
        return
    end

    git_worktree.switch_worktree(nil)

    local worktree_path = get_worktree_path(prompt_bufnr)
    actions.close(prompt_bufnr)
    if worktree_path ~= nil then
        git_worktree.delete_worktree(worktree_path, force_next_deletion, {
            on_failure = delete_failure_handler,
            on_success = delete_success_handler,
        })
    end
end

-- Build the worktree path from a name, replacing special characters with '-'
-- @param name string: the branch/tag/custom name to use
-- @return string: the worktree path (relative)
local build_worktree_path = function(name)
    local sanitized = name:gsub('[^%w%.%-_]', '-')
    local is_inside_work_tree = vim.fn.system('git rev-parse --is-inside-work-tree')
    local prefix = is_inside_work_tree == 'true\n' and '../' or './'
    return prefix .. 'wt-' .. sanitized
end

-- Create a prompt to get the path of the new worktree
-- @param cb function: the callback to call with the path
-- @return nil
local create_input_prompt = function(opts, cb)
    opts = opts or {}
    opts.pattern = nil -- show all branches that can be tracked

    -- CUSTOM CODE -- START
    local path = build_worktree_path(opts.branch)
    -- CUSTOM CODE -- FINISH

    if path == '' then
        Log.error('No worktree path provided')
        return
    end

    if opts.branch == '' then
        Log.error('opts.branch not provided')
        cb(path, nil)
        return
    end

    local branches = vim.fn.systemlist('git branch --all')
    if #branches == 0 then
        cb(path, nil)
        return
    end

    local remotes = vim.fn.systemlist('git remote')
    -- remotes = origin | upstream etc, remotes[1] sería origin

    if #remotes == 0 then
        Log.info('No remotes found')
        cb(path, nil)
        return
    end

    -- remote whitespaces
    for i, v in ipairs(remotes) do
        remotes[i] = string.gsub(v, '^%s+', '')
    end

    local remote = remotes[1]
    local remote_branches = vim.fn.systemlist('git branch --remotes --list')

    for i, v in ipairs(remote_branches) do
        remote_branches[i] = string.gsub(v, '^%s+', '')
    end

    local remote_branch = remote .. '/' .. opts.branch
    -- print('Remote branch: ', remote_branch)
    -- print('remote branches: ', vim.inspect(remote_branches))

    local function is_present_in_table(tbl, str)
        for _, value in ipairs(tbl) do
            if value == str then
                return true
            end
        end
        return false
    end

    local is_remote_branch_in_remote_branches_list = is_present_in_table(remote_branches, remote_branch)

    if is_remote_branch_in_remote_branches_list then
        Log.info('Remote branch found: ' .. remote_branch)
        cb(path, remote_branch)
        return
    else
        cb(path, nil)
    end

    -- local confirmed = vim.fn.input('Track an upstream? [y/n]: ')
    -- if string.sub(string.lower(confirmed), 0, 1) == 'y' then
    --     opts.attach_mappings = function()
    --         actions.select_default:replace(function(prompt_bufnr, _)
    --             local selected_entry = action_state.get_selected_entry()
    --             local current_line = action_state.get_current_line()
    --             actions.close(prompt_bufnr)
    --             local upstream = selected_entry ~= nil and selected_entry.value or current_line
    --             cb(path, upstream)
    --         end)
    --         return true
    --     end
    --     require('telescope.builtin').git_branches(opts)
    -- else
    --     cb(path, nil)
    -- end
end

-- Create a worktree
-- @param opts table: the options for the telescope picker (optional)
-- @return nil
local telescope_create_worktree = function(opts)
    -- git_worktree.switch_worktree(nil)
    opts = opts or {}

    -- local create_branch = function(prompt_bufnr, _)
    --     -- if current_line is still not enough to filter everything but user
    --     -- still wants to use it as the new branch name, without selecting anything
    --     local branch = action_state.get_current_line()
    --     if branch == nil or branch == '' then
    --         branch = action_state.get_selected_entry().name
    --     end
    --
    --     actions.close(prompt_bufnr)
    --
    --     opts.branch = branch
    --
    --     if starts_with(branch, 'origin') then
    --         branch = removePrefix(branch, 'origin/')
    --         opts.branch = branch
    --
    --         local job = Job:new {
    --             command = 'git',
    --             args = { 'branch', '--track', branch, 'origin/' .. branch },
    --             cwd = vim.loop.cwd(),
    --             on_stderr = function(_, data)
    --                 Log.error('ERROR: ' .. data)
    --             end,
    --         }
    --
    --         local stdout, code = job:sync()
    --
    --         if code ~= 0 then
    --             Log.error(
    --                 'Error running git branch --track'
    --                     .. branch
    --                     .. ' origin/'
    --                     .. branch
    --                     .. ': code:'
    --                     .. tostring(code)
    --                     .. ' out: '
    --                     .. table.concat(stdout, '')
    --                     .. '.'
    --             )
    --             return nil
    --         end
    --     end
    --
    --     create_input_prompt(opts, function(path, upstream)
    --         git_worktree.create_worktree(path, branch, upstream)
    --     end)
    -- end

    local select_or_create_branch = function(prompt_bufnr, custom_name)
        local selected_entry = action_state.get_selected_entry()
        local current_line = action_state.get_current_line()
        actions.close(prompt_bufnr)
        -- selected_entry can be null if current_line filters everything
        -- and there's no branch shown

        local branch
        local is_tag_selection = false

        if selected_entry == nil then
            branch = current_line
        end

        if current_line == '' and selected_entry ~= nil then
            branch = selected_entry.value
            is_tag_selection = selected_entry.type == 'tag'
        end

        if current_line ~= '' and selected_entry ~= nil then
            branch = selected_entry.value
            is_tag_selection = selected_entry.type == 'tag'
        end

        if branch == nil or branch == '' then
            Log.error('No branch selected')
            return
        end

        -- If it's a tag, create a worktree with wt-<tag> branch name
        if is_tag_selection then
            local tag_name = branch
            local new_branch = 'wt-' .. tag_name
            local path = custom_name and build_worktree_path(custom_name) or build_worktree_path(tag_name)

            -- Check if a worktree already exists for this tag
            local git_worktree_list_output = vim.fn.systemlist('git worktree list')
            for _, line in ipairs(git_worktree_list_output) do
                if string.find(line, new_branch) then
                    vim.notify('Worktree already exists for tag: ' .. tag_name, vim.log.levels.ERROR)
                    return
                end
            end

            -- Create worktree for tag: git worktree add -b wt-<tag> <path> <tag>
            local job = Job:new {
                command = 'git',
                args = { 'worktree', 'add', '-b', new_branch, path, tag_name },
                cwd = vim.loop.cwd(),
                on_stderr = function(_, data)
                    Log.error('ERROR: ' .. data)
                end,
                on_exit = function(_, code)
                    if code == 0 then
                        vim.schedule(function()
                            vim.notify('Created worktree for tag ' .. tag_name .. ' at ' .. path, vim.log.levels.INFO)
                            git_worktree.switch_worktree(path)
                        end)
                    else
                        vim.schedule(function()
                            vim.notify('Failed to create worktree for tag ' .. tag_name, vim.log.levels.ERROR)
                        end)
                    end
                end,
            }
            job:start()
            return
        end

        opts.branch = branch

        -- check if a worktree is already created for this branch
        local git_worktree_list_output = vim.fn.systemlist('git worktree list')
        for _, line in ipairs(git_worktree_list_output) do
            if string.find(line, branch) then
                vim.notify('Worktree already exists for branch: ' .. branch, vim.log.levels.ERROR)
                return
            end
        end

        if starts_with(branch, 'origin') then
            branch = removePrefix(branch, 'origin/')
            opts.branch = branch

            local job = Job:new {
                command = 'git',
                args = { 'branch', '--track', branch, 'origin/' .. branch },
                cwd = vim.loop.cwd(),
                on_stderr = function(_, data)
                    Log.error('ERROR: ' .. data)
                end,
            }

            local stdout, code = job:sync()

            if code ~= 0 then
                Log.error(
                    'Error running git branch --track'
                        .. branch
                        .. ' origin/'
                        .. branch
                        .. ': code:'
                        .. tostring(code)
                        .. ' out: '
                        .. table.concat(stdout, '')
                        .. '.'
                )
                return nil
            end
        end

        create_input_prompt(opts, function(path, upstream)
            -- Override the auto-generated path when the user provided a custom name
            if custom_name then
                path = build_worktree_path(custom_name)
            end

            local git_status_is_porcelain = function()
                local output = vim.fn.systemlist('git status --porcelain')
                if #output > 0 then
                    return false
                end
                return true
            end

            -- We do NOT have git changes
            if current_line == nil or current_line == '' or git_status_is_porcelain() then
                git_worktree.create_worktree(path, branch, upstream)
                return
            end

            -- We do have git changes
            local stash_job = Job:new {
                command = 'git',
                args = { 'stash', '--include-untracked' },
                cwd = vim.loop.cwd(),
                on_stderr = function(_, data)
                    Log.error('ERROR: ' .. data)
                end,
            }
            stash_job:sync()

            local stash_apply_job = Job:new {
                command = 'git',
                args = { 'stash', 'apply' },
                cwd = vim.loop.cwd(),
                on_stderr = function(_, data)
                    Log.error('ERROR: ' .. data)
                end,
            }
            stash_apply_job:sync()

            git_worktree.create_worktree(path, branch, upstream, true)
        end)
    end

    opts.attach_mappings = function(_, map)
        actions.select_default:replace(function(prompt_bufnr)
            select_or_create_branch(prompt_bufnr, nil)
        end)
        map({ 'i', 'n' }, '<C-e>', function(prompt_bufnr)
            local custom_name = vim.fn.input('Worktree name (wt- will be prepended): ')
            if custom_name == nil or custom_name == '' then
                return
            end
            select_or_create_branch(prompt_bufnr, custom_name)
        end)
        return true
    end

    -- Create a custom picker with both branches and tags with metadata
    local branch_job = Job:new {
        command = 'git',
        args = { 'branch', '--all', '--format=%(refname:short)|%(authorname)|%(committerdate:relative)|%(subject)' },
    }
    local branch_lines = branch_job:sync()

    local tag_job = Job:new {
        command = 'git',
        args = {
            'for-each-ref',
            '--sort=-creatordate',
            '--format=%(refname:short)|%(authorname)|%(authordate:relative)|%(subject)',
            'refs/tags',
        },
    }
    local tag_lines = tag_job:sync()

    -- Combine branches and tags with type information and metadata
    local results = {}
    local widths = {
        name = 0,
        author = 0,
        date = 0,
    }

    -- Parse branches
    for _, line in ipairs(branch_lines) do
        local parts = vim.split(line, '|', { plain = true })
        local entry = {
            value = parts[1] or '',
            type = 'branch',
            author = parts[2] or '',
            date = parts[3] or '',
            subject = parts[4] or '',
        }
        table.insert(results, entry)

        -- Update widths
        widths.name = math.max(widths.name, strings.strdisplaywidth(entry.value))
        widths.author = math.max(widths.author, strings.strdisplaywidth(entry.author))
        widths.date = math.max(widths.date, strings.strdisplaywidth(entry.date))
    end

    -- Parse tags
    for _, line in ipairs(tag_lines) do
        local parts = vim.split(line, '|', { plain = true })
        local entry = {
            value = parts[1] or '',
            type = 'tag',
            author = parts[2] or '',
            date = parts[3] or '',
            subject = parts[4] or '',
        }
        table.insert(results, entry)

        -- Update widths (add space for [tag] marker)
        widths.name = math.max(widths.name, strings.strdisplaywidth(entry.value .. ' [tag]'))
        widths.author = math.max(widths.author, strings.strdisplaywidth(entry.author))
        widths.date = math.max(widths.date, strings.strdisplaywidth(entry.date))
    end

    -- Create displayer
    local displayer = require('telescope.pickers.entry_display').create {
        separator = ' ',
        items = {
            { width = widths.name },
            { width = widths.author },
            { width = widths.date },
            { remaining = true },
        },
    }

    local make_display = function(entry)
        local display_name = entry.value
        local name_hl = 'TelescopeResultsIdentifier'

        if entry.type == 'tag' then
            display_name = entry.value .. ' [tag]'
        end

        return displayer {
            { display_name, name_hl },
            { entry.author, 'TelescopeResultsComment' },
            { entry.date, 'TelescopeResultsSpecialComment' },
            { entry.subject, 'TelescopeResultsComment' },
        }
    end

    pickers
        .new(opts, {
            prompt_title = 'Create Worktree (Branches & Tags)',
            finder = finders.new_table {
                results = results,
                entry_maker = function(entry)
                    return {
                        value = entry.value,
                        display = make_display,
                        ordinal = entry.value,
                        type = entry.type,
                        author = entry.author,
                        date = entry.date,
                        subject = entry.subject,
                    }
                end,
            },
            sorter = conf.generic_sorter(opts),
            attach_mappings = opts.attach_mappings,
        })
        :find()
end

-- List the git worktrees
-- @param opts table: the options for the telescope picker (optional)
-- @return nil
local telescope_git_worktree = function(opts)
    opts = opts or {}
    local output = utils.get_os_command_output { 'git', 'worktree', 'list' }
    local results = {}
    local widths = {
        path = 0,
        sha = 0,
        branch = 0,
    }

    local parse_line = function(line)
        local fields = vim.split(string.gsub(line, '%s+', ' '), ' ')
        local entry = {
            path = fields[1],
            sha = fields[2],
            branch = fields[3],
        }

        if entry.sha ~= '(bare)' then
            local index = #results + 1
            for key, val in pairs(widths) do
                if key == 'path' then
                    local path_len = strings.strdisplaywidth(entry[key] or '')
                    widths[key] = math.max(val, path_len)
                else
                    widths[key] = math.max(val, strings.strdisplaywidth(entry[key] or ''))
                end
            end

            table.insert(results, index, entry)
        end
    end

    for _, line in ipairs(output) do
        parse_line(line)
    end

    -- if #results == 0 then
    --     return
    -- end

    local displayer = require('telescope.pickers.entry_display').create {
        separator = ' ',
        items = {
            { width = widths.branch },
            { width = widths.path },
            { width = widths.sha },
        },
    }

    local make_display = function(entry)
        local path, _ = utils.transform_path(opts, entry.path)
        return displayer {
            { entry.branch, 'TelescopeResultsIdentifier' },
            { path },
            { entry.sha },
        }
    end

    pickers
        .new(opts or {}, {
            prompt_title = 'Git Worktrees',
            finder = finders.new_table {
                results = results,
                entry_maker = function(entry)
                    entry.value = entry.branch
                    entry.ordinal = entry.branch
                    entry.display = make_display
                    return entry
                end,
            },
            sorter = conf.generic_sorter(opts),
            attach_mappings = function(_, map)
                action_set.select:replace(switch_worktree)

                map('i', '<tab>', function()
                    telescope_create_worktree {}
                end)
                map('n', '<tab>', function()
                    telescope_create_worktree {}
                end)
                map('i', '<c-x>', delete_worktree)
                map('n', '<c-x>', delete_worktree)
                map('i', '<c-f>', toggle_forced_deletion)
                map('n', '<c-f>', toggle_forced_deletion)
                map({ 'i', 'n' }, '<c-y>', function(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    if selection == nil then
                        vim.notify('No worktree selected', vim.log.levels.WARN)
                        return
                    end
                    local branch = selection.branch
                    -- Strip surrounding brackets from [branch-name]
                    branch = branch:gsub('^%[', ''):gsub('%]$', '')
                    if branch == nil or branch == '' or branch == 'HEAD' then
                        vim.notify('Cannot merge: no valid branch for selected worktree', vim.log.levels.WARN)
                        return
                    end
                    local confirmed = vim.fn.input('Merge branch "' .. branch .. '" into current branch? [y/n]: ', 'y')
                    if string.sub(string.lower(confirmed), 1, 1) ~= 'y' then
                        vim.notify('Merge canceled', vim.log.levels.INFO)
                        return
                    end
                    actions.close(prompt_bufnr)
                    local _, ret, stderr = utils.get_os_command_output { 'git', 'merge', branch }
                    if ret == 0 then
                        vim.notify('Merged branch: ' .. branch, vim.log.levels.INFO)
                    else
                        vim.notify(
                            'Error merging branch: ' .. branch .. '. Git returned: ' .. table.concat(stderr, ' '),
                            vim.log.levels.ERROR
                        )
                    end
                end)

                return true
            end,
        })
        :find()
end

-- Register the extension
-- @return table: the extension
return require('telescope').register_extension {
    exports = {
        git_worktree = telescope_git_worktree,
        create_git_worktree = telescope_create_worktree,
    },
}
