" Vim syntax file
" Language: kdesrc-build configuration file
" Maintainer: Michael Pyne <mpyne@kde.org>
" Latest Revision: 30 April 2019

" Copyright (c) 2014-2019 Michael Pyne <mpyne@kde.org>
" Redistribution and use in source and binary forms, with or without
" modification, are permitted provided that the following conditions
" are met:
"
" 1. Redistributions of source code must retain the above copyright
"    notice, this list of conditions and the following disclaimer.
" 2. Redistributions in binary form must reproduce the above copyright
"    notice, this list of conditions and the following disclaimer in the
"    documentation and/or other materials provided with the distribution.
"
" THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
" IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
" OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
" IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
" INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
" NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
" DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
" THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
" (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
" THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

if exists("b:current_syntax")
    finish
endif

syn case match

" We use Lisp-style keywords
setlocal iskeyword+=-

" Keywords
syn keyword ksbrcOption contained skipwhite nextgroup=ksbrcStringValue
            \ binpath branch build-dir checkout-only cmake-options configure-flags
            \ custom-build-command cxxflags dest-dir do-not-compile kdedir
            \ libpath log-dir make-install-prefix make-options module-base-path
            \ ninja-options
            \ override-build-system override-url prefix qtdir repository
            \ revision source-dir svn-server tag remove-after-install
            \ qmake-options git-user

syn keyword ksbrcGlobalOption contained skipwhite nextgroup=ksbrcStringValue
            \ branch-group git-desired-protocol git-repository-base http-proxy
            \ kde-languages niceness debug-level persistent-data-file set-env

" MUST BE CONSISTENT WITH ABOVE. Used when a module-set option is used in the
" wrong spot to highlight the error.
syn keyword ksbrcErrorGlobalOption contained skipwhite nextgroup=ksbrcStringValue
            \ branch-group git-desired-protocol git-repository-base http-proxy
            \ kde-languages niceness debug-level persistent-data-file set-env

syn keyword ksbrcModuleSetOption contained skipwhite nextgroup=ksbrcStringValue
            \ use-modules ignore-modules

" MUST BE CONSISTENT WITH ABOVE. Used when a module-set option is used in the
" wrong spot to highlight the error.
syn keyword ksbrcErrorModuleSetOption contained skipwhite nextgroup=ksbrcStringValue
            \ use-modules ignore-modules

syn keyword ksbrcBoolOption contained skipwhite nextgroup=ksbrcBoolValue
            \ build-system-only build-when-unchanged ignore-kde-structure
            \ include-dependencies install-after-build manual-build manual-update
            \ no-src reconfigure recreate-configure refresh-build run-tests
            \ use-clean-install

syn keyword ksbrcGlobalBoolOption contained skipwhite nextgroup=ksbrcBoolValue
            \ async colorful-output disable-agent-check disable-snapshots pretend
            \ purge-old-logs stop-on-failure use-idle-io-priority install-session-driver
            \ install-environment-driver

" MUST BE CONSISTENT WITH ABOVE. Used when a global option is used in the
" wrong spot to highlight the error.
syn keyword ksbrcErrorBoolOption contained skipwhite nextgroup=ksbrcBoolValue
            \ async colorful-output disable-agent-check disable-snapshots pretend
            \ purge-old-logs stop-on-failure use-idle-io-priority install-session-driver
            \ install-environment-driver

" Matches
syn match ksbrcKeyword "\<end\s\+global\>"
syn match ksbrcKeyword "\<end\s\+module\>"
syn match ksbrcKeyword "\<end\s\+options\>"
syn match ksbrcKeyword "\<end\s\+module-set\>"


syn match ksbrcPath "\S*$" contained
syn match ksbrcKeyword "^\s*include\>" skipwhite nextgroup=ksbrcPath

" This is a 'region' instead of a match to allow line continuations to work (a
" match will never break across lines). 100% accuracy would demand that all
" possible values/lines can be broken, but it makes no sense other than option
" values so that's where I'll leave it for now.
"
" Since we're using a region we need to stop before comments manually, or stop
" at EOL if there are no comments (which is why there's multiple end=). The
" me=s-1 part to the 'end before comment' clause ensures that the comment and
" any preceding whitespace isn't 'eaten up' by this match.
syn region ksbrcStringValue start="\S" end="$" end="\s*#"me=s-1 contained contains=ksbrcLineContinue

syn match ksbrcBoolValue "\c\<true\|false\|0\|1\>" contained

syn match ksbrcComment "#.*$"

" Regions
syn region ksbrcModuleSetRegion fold matchgroup=ksbrcKeyword
            \ start="module-set\>" end="end module-set"
            \ contains=ksbrcComment,ksbrcOption,ksbrcModuleSetOption,ksbrcBoolOption,ksbrcErrorBoolOption,ksbrcErrorGlobalOption
syn region ksbrcGlobalRegion fold matchgroup=ksbrcKeyword
            \ start="global\>" end="end global"
            \ contains=ksbrcComment,ksbrcOption,ksbrcGlobalOption,ksbrcGlobalBoolOption,ksbrcBoolOption,ksbrcErrorModuleSetOption

" These two regions should be about equivalent. Probably could just duplicate
" the start= and end=, which vim supports, except that the end might not match
" the corresponding start=
syn region ksbrcModuleRegion fold matchgroup=ksbrcKeyword
            \ start='module\>\(-set\)\@!' end='end module'
            \ contains=ksbrcComment,ksbrcOption,ksbrcBoolOption,ksbrcErrorBoolOption,ksbrcErrorModuleSetOption,ksbrcErrorGlobalOption
syn region ksbrcOptionsRegion fold matchgroup=ksbrcKeyword
            \ start="options\>" end="end options"
            \ contains=ksbrcComment,ksbrcOption,ksbrcBoolOption,ksbrcErrorBoolOption,ksbrcErrorModuleSetOption,ksbrcErrorGlobalOption

" Handle continuation lines
syn match ksbrcLineContinue "\\$" contained

" Footer boilerplate
let b:current_syntax = "kdesrc-buildrc"

" Help vim find where to start highlighting (I think...)
syn sync match SyncRegionEnd grouphere NONE "^\s*end\s\+\(module\|module-set\|options\)\s*$"

" Link our styles to standard styles
hi def link ksbrcKeyword Keyword
hi def link ksbrcComment Comment
hi def link ksbrcPath Include
hi def link ksbrcStringValue String
hi def link ksbrcBoolValue Boolean

hi def link ksbrcOption Identifier
hi def link ksbrcGlobalOption Identifier
hi def link ksbrcBoolOption Identifier
hi def link ksbrcGlobalBoolOption Identifier
hi def link ksbrcModuleSetOption Identifier

hi def link ksbrcLineContinue Special

hi def link ksbrcErrorBoolOption Error
hi def link ksbrcErrorModuleSetOption Error
hi def link ksbrcErrorGlobalOption Error

" vim: set ft=vim:
