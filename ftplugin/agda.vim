" Author: Marcin Szamotulski
"
" Agda filetype plugin
"
" This is a simple integration with 'agda --interaction-json' server.
" You can set goald in your agda file with '?' or '{! !}'.  Unlike agda-mode
" (emacs) this plugin will not rename them with unique identifiers, but rather
" put corresponding values in a quickfix list.  To find the line positions the
" plugin is inefficiently scanning source file.
"
" It runs a single 'agda' process and communicates with it.
"
" TODO
" large agda files make vim unresponsive.  Use a queue, and track
" update in callbacks.

setl expandtab

" Nah, global reference
if !exists("s:agda")
  let s:agda = v:null
endif
let s:qf_open   = v:false
let s:qf_append = v:false

let g:AgdaVimDebug = v:false

fun! StartAgdaInteraction()
  if s:agda == v:null
    let s:agda = job_start(
          \ ["agda", "--interaction-json"],
          \ { "out_cb": "HandleAgdaMsg"
	  \ , "err_cb": "HandleAgdaErrorMsg"
          \ , "stoponexit": "term"
          \ })
  endif
  return s:agda
endfun

fun! StopAgdaInteraction()
  if s:agda == v:null
    return
  endif
  call job_stop(s:agda)
  let s:agda = v:null
endfun

fun! HandleAgdaErrMsg(chan, msg)
  echohl ErrorMsg
  echom msg
  echohl Normal
endfun

fun! HandleAgdaMsg(chan, msg)
  " This is only called when messages are not read from the corresponding
  " channel.
  if a:msg =~# '^JSON> '
    let msg = strpart(a:msg, 6)
  else
    let msg = a:msg
  endif
  try
    silent let output = json_decode(msg)
  catch /.*/
    echohl ErrorMsg
    echom msg
    echohl Normal
    return
  endtry
  if type(output) == 4
    if output["kind"] == "DisplayInfo"
      call HandleDisplayInfo(output)
    elseif output["kind"] == "GiveAction"
      call HandleGiveAction(output)
    elseif g:AgdaVimDebug
      echom "HandleAgdaMsg <" . string(msg) . ">"
    endif
  else
    if g:AgdaVimDebug
      echom "HandleAgdaMsg <" . string(msg) . ">"
    endif
  endif
endfun

fun! AgdaCommand(file, cmd)
  " TODO: process busy state
  if s:agda == v:null
    echoerr "agda is not running"
    return
  endif
  let chan = job_getchannel(s:agda)
  call ch_sendraw(
        \   chan
        \ , "IOTCM \""
            \ . fnameescape(a:file)
            \ . "\" None Direct "
            \ . a:cmd
            \ . "\n")
endfunc

fun! IsLiterateAgda()
  return expand("%:e") == "lagda"
endfun

" goals
let b:goals = []

fun! FindGoals()
  " Find all lines in which there is at least one goal
  let view = winsaveview()
  let ps   = [] " list of lines
  silent global /\v(^\?|\s\?|\{\!.{-}\!\})/ :call add(ps, getpos(".")[1])
  if IsLiterateAgda()
    " filter out lines which are not indside code LaTeX environment
    let ps_ = []
    for l in ps
      call setpos(".", [0, l, 0, 0])
      if searchpair('\\begin{code}', '', '\\end{code}', 'bnW') == 0
	" not inside
	continue
      else
	call add(ps_, l)
      endif
    endfor
    let ps = ps_
  endif
  call winrestview(view)
  return ps
endfun

fun! EnumGoals(ps)
  " ps list of linue numbers with goals
  let ps_ = []
  for lnum in a:ps
    " todo: support for multiple goals in a single line
    let col = 0
    let g:subs = split(getline(lnum), '\ze\v(\?|\{\!)')
    for sub in g:subs
      if col == 0 && sub =~ '^\v(\?|\{\!)'
	call add(ps_, [lnum, col + 1])
      endif
      let col += len(sub)
      if col >= len(getline(lnum))
	break
      endif
      call add(ps_, [lnum, col + 1])
    endfor
  endfor
  let b:goals = ps_
  return ps_
endfun

fun! FindAllGoals()
  " Find all goals and return their positions.
  return EnumGoals(FindGoals())
endfun

" DisplayInfo message callback, invoked asyncronously by HandleAgdaMsg
fun! HandleDisplayInfo(info)
  let ps = FindAllGoals()
  let info = a:info["info"]
  let g:info = info
  let qflist = []
  if info["kind"] == "AllGoalsWarnings"
    let goals = split(get(info, "goals", ""), "\n")
    let n = 0
    for goal in goals
      let [lnum, col] = get(ps, n, [0, 0]) " this is terrible!
      call add(qflist,
	    \ { "bufnr": bufnr("")
	    \ , "filename": expand("%")
	    \ , "lnum": lnum
	    \ , "col":  col
	    \ , "text": goal
	    \ , "type": "G"
	    \ })
      let n+=1
    endfor
    " TODO
    " if the user changed buffers, the errors might end up in the wrong
    " quickfix list
    call setqflist(qflist, s:qf_append ? 'a' : 'r')
    call setqflist([], 'a',
	  \ { 'lines': split(get(info, "warnings", ""), "\n")
	  \ , 'efm': s:efm_warning
	  \ })
    call setqflist([], 'a',
	  \ { 'lines': split(get(info, "errors", ""), "\n")
	  \ , 'efm': s:efm_error
	  \ })
  elseif info["kind"] == "Error"
    call setqflist([], s:qf_append ? 'a' : 'r',
	  \ { 'lines': split(info["payload"], "\n")
	  \ , 'efm': s:efm_error
	  \ })
  elseif info["kind"] == "CurrentGoal" || info["kind"] == "Version" || info["kind"] == "Intro"
    echohl WarningMsg
    echo info["payload"]
    echohl Normal
  else
    if g:AgdaVimDebug
      echom "DisplayInfo " . json_encode(info)
    endif
  endif

  let s:qf_append = v:true

  " TODO
  " this is called by various commands, it's not always makes sense to re-open
  " quickfix list
  if s:qf_open
    if len(getqflist()) > 0
      copen
      wincmd p
      let s:qf_open = v:false
    else
      cclose
    endif
  endif
endfun

fun! HandleGiveAction(action)
  " Cmd_refine_or_intro
  " Assuming we are on the right interaction point
  echom a:action
  let result = a:action["giveResult"]
  if strpart(getline(line(".")), col(".") - 1)[0] == "?"
    exe "normal s" . result
  else
    exe "normal ca{" . result
  endif
endfun

fun! AgdaLoad(bang, file)
  if a:bang == "!"
    update
  endif
  let s:qf_open   = v:true
  let s:qf_append = v:false

  if s:agda == v:null
    echoerr "agda is not running"
    return
  endif
  call AgdaCommand(a:file, "(Cmd_load \"" . fnameescape(a:file) . "\" [])")
endfun

fun! AgdaAbort(file)
  call AgdaCommand(a:file, "Cmd_abort")
  let s:agda = v:null
endfun

fun! AgdaCompile(file, backend)
  " agda2-mode.el:840
  call AgdaCommand(a:file, "(Cmd_compile " . a:backend . " \"" . fnameescape(a:file) . "\" [])")
endfun

fun! AgdaAutoAll(file)
  " agda2-mode.el:917
  " busy
  call AgdaCommand(a:file, "Cmd_autoAll")
endfun

fun! AgdaMetas(file)
  " agda2-mode.el:1096
  " busy
  call AgdaCommand(a:file, "Cmd_metas")
endfun

fun! AgdaConstraints(file)
  " agda2-mode.el:1096
  " busy
  call AgdaCommand(a:file, "Cmd_constraints")
endfun


fun! GetCurrentGoal()
  " Find current goal, this finds default to the previous goal.
  let [_, lnum, col, _] = getpos(".")
  return len(filter(FindAllGoals(), {idx, val -> val[0] < lnum || val[0] == lnum && val[1] <= col })) - 1 " goals are enumerated from 0
endfun

fun! AgdaGoal(file)
  " agda2-mode.el:748
  " CMD <goal number> <goal range> <user input> args
  let n = GetCurrentGoal()
  if n >= 0
    " testing commands
    " https://github.com/banacorn/agda-mode/blob/master/src/Command.re
    let cmd = "(Cmd_solveOne " . n . " noRange)"
    echom cmd
    call AgdaCommand(a:file, cmd)
    let chan = job_getchannel(s:agda)
    let msg = ch_read(chan)
    echom msg
    "JSON> cannot read: IOTCM \"src/plfa/Lists.lagda\" None Direct Cmd_solveOne 0 noRange
  endif
endfun

fun! AgdaGoalType(file)
  let n = GetCurrentGoal()
  if n >= 0
    let cmd = "(Cmd_goal_type Normalised " . n . " noRange \"\")"
    echom cmd
    call AgdaCommand(a:file, cmd)
  endif
endfun

fun! AgdaShowModuleContentsToplevel(file)
  let cmd = "(Cmd_show_module_contents_toplevel Normalised \"\")"
  call AgdaCommand(a:file, cmd)
endfun

fun! AgdaInferToplevel(file, expr)
  let cmd = "(Cmd_infer_toplevel Normalised \"" . a:expr . "\")"
  call AgdaCommand(a:file, cmd)
endfun

fun! AgdaShowVersion(file)
  let cmd = "Cmd_show_version"
  call AgdaCommand(a:file, cmd)
endfun

fun! AgdaWhyInScopeToplevel(file, str)
  let cmd = "(Cmd_why_in_scope_toplevel \"" . a:str . "\")"
  call AgdaCommand(a:file, cmd)
endfun

fun! AgdaRefine(file) 
  let n = GetCurrentGoal()
  if n >= 0
    let cmd = "(Cmd_refine " . n . " noRange \"\")"
    call AgdaCommand(a:file, cmd)
  endif
endfun

fun! AgdaRefineOrIntro(file) 
  let n = GetCurrentGoal()
  if n >= 0
    let cmd = "(Cmd_refine_or_intro True " . n . " noRange \"\")"
    call AgdaCommand(a:file, cmd)
  endif
endfun

" Cmd_why_in_scope index noRange content
" Cmd_why_in_scope_toplevel content

com! -buffer -bang AgdaLoad    :call AgdaLoad("<bang>", expand("%:p"))
com! -buffer       AgdaMetas   :call AgdaMetas(expand("%:p"))
com! -buffer       AgdaRestart :call AgdaAbort(expand("%:p"))|call StartAgdaInteraction()
com! -buffer       AgdaVersion :call AgdaShowVersion(expand("%:p"))
com! -buffer       AgdaGoalType :call AgdaGoalType(expand("%:p"))
com! -buffer       AgdaRefine  :call AgdaRefineOrIntro(expand("%:p"))

com! -buffer       StartAgda   :call StartAgdaInteraction()

" The same map as in agda-mode
nm <buffer> <silent> <c-c><c-l> :<c-u>AgdaLoad!<cr>

" start 'agda --interaction-json'
call StartAgdaInteraction()
