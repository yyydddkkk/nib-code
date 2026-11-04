"""OpenAI-compatible streaming mock. Usage: mock_llm.py PORT LOGFILE

A user message triggers one `run` tool call (bash: echo + wc); the following
request (last message is a tool result) gets a text answer quoting it.
A user message containing "bad" makes the script use TypeScript syntax;
"fail2" makes the second request of the Turn return HTTP 500.
Summary requests return a short fixed summary without tool calls.
"timing" streams UTF-8 Run arguments and invokes bash, write, then read.
Set MOCK_PROMPT_TOKENS to override usage before compaction; summarized requests
report a byte-based token estimate. Thinking is on unless the request sends
thinking.type "disabled": replies then stream reasoning_content, and like
DeepSeek, a request with tools whose assistant messages lack reasoning_content
gets HTTP 400. "reject1"/"reject2" return HTTP 400 before
the first/second Step; "truncated" closes the stream without [DONE].
"delegate" runs two children; "delegate_many" runs six; "delegate_failure"
catches a failed child's error. "delegate_progress" runs two children through three Runs each (write, edit, read), with pauses between Steps. "delegate_cancel PATH" runs a child whose bash
writes its pid to PATH and sleeps. "child probe" answers without a Run. A /reflect request answers with two
issue drafts, one carrying a fake credential. "interrupt me" streams
partial text, then stalls for a second; "interrupt stalled" stalls for 30 seconds. "edit_test" writes and
edits files. "fetch_test" fetches GET /redirect (to /page) and
/slow (3 s) with a short timeout; GET serves those pages.
Child Runs report the exposed tools, allowing depth-limit checks.
Each request is logged to LOGFILE as one JSON line, with a monotonic received time."""
import http.server, json, os, shlex, sys, threading, time
from mock_llm_tool import run_code as llm_run_code, serve as serve_llm, serve_effort
LOG=open(sys.argv[2],'a')
LOG_LOCK = threading.Lock()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302); self.send_header('location','/page'); self.send_header('content-length','0'); self.end_headers(); return
        if self.path == '/large':
            body = b'x' * (1024 * 1024 + 10)
            self.send_response(200); self.send_header('content-type','text/plain'); self.send_header('content-length',str(len(body))); self.end_headers()
            try: self.wfile.write(body)
            except OSError: pass
            return
        if self.path == '/slow':
            time.sleep(3)
        body = '<html><head><title>t</title></head><body><nav>menu</nav><main><h1>Mock page</h1><p>Accept: ' + self.headers.get('accept','') + '</p></main></body></html>'
        self.send_response(200); self.send_header('content-type','text/html; charset=utf-8'); self.send_header('content-length',str(len(body.encode()))); self.end_headers()
        try: self.wfile.write(body.encode())
        except OSError: pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['content-length'])))
        msgs=body['messages']
        with LOG_LOCK:
            LOG.write(json.dumps({"received":time.monotonic(),"n":len(msgs),"roles":[m['role'] for m in msgs],"has_tools":(body.get('tools') or [{}])[0].get('function',{}).get('name'),
                              "messages":msgs,"thinking":body.get('thinking'),"reasoning_effort":body.get('reasoning_effort'),"has_reasoning_effort":'reasoning_effort' in body,"system_has_tools_api":'const tools = {' in msgs[0].get('content','')})+"\n"); LOG.flush()
        if serve_effort(self, body, "chat_completions"):
            return
        if serve_llm(self, body, 'chat_completions'):
            return
        summary = 'max_tokens' in body and not body.get('tools')
        lastuser=[m for m in msgs if m['role']=='user'][-1]['content']
        if ('reject1' in lastuser or (msgs[-1]['role']=='tool' and 'reject2' in lastuser)) and not summary:
            self.send_response(400); self.send_header('content-type','application/json'); self.end_headers(); self.wfile.write(b'{"error":"rejected"}'); return
        thinking = (body.get('thinking') or {}).get('type') != 'disabled'
        if thinking and body.get('tools') and any(m['role']=='assistant' and not m.get('reasoning_content') for m in msgs):
            self.send_response(400); self.send_header('content-type','application/json'); self.end_headers()
            self.wfile.write(b'{"error":{"message":"The reasoning_content in the thinking mode must be passed back to the API."}}'); return
        progress_child = lastuser.startswith('child progress ')
        completed_runs = sum(m['role'] == 'tool' for m in msgs)
        if progress_child and completed_runs:
            time.sleep(3 if lastuser.endswith('beta') and completed_runs == 3 else 1.25)
        if msgs[-1]['role']=='tool' and lastuser == 'child stall2':
            time.sleep(3)
        if msgs[-1]['role']=='tool' and 'fail2' in lastuser:
            self.send_response(500); self.send_header('content-type','application/json'); self.end_headers(); self.wfile.write(b'{"error":"boom"}'); return
        self.send_response(200); self.send_header('content-type','text/event-stream'); self.send_header('transfer-encoding','chunked'); self.end_headers()
        def ev(obj):
            d=('data: '+json.dumps(obj)+'\n\n').encode()
            self.wfile.write(b'%x\r\n'%len(d)+d+b'\r\n'); self.wfile.flush(); time.sleep(0.01)
        last=msgs[-1]
        if lastuser == 'timing':
            heartbeat = b': ping\n\n'
            self.wfile.write(b'%x\r\n' % len(heartbeat) + heartbeat + b'\r\n')
            self.wfile.flush()
            time.sleep(.1)
        compacted = any(m.get('content','').startswith('Earlier session summary:') for m in msgs)
        def prompt_tokens(default):
            if compacted:
                return sum(len(m.get('content') or '') for m in msgs)//3
            if lastuser in ('one', 'two', 'three', 'json compact'):
                return 6500
            return int(os.environ.get('MOCK_PROMPT_TOKENS', default))
        if summary:
            ev({'choices':[{'delta':{'content':'Earlier work: ran bash successfully. Continue the user task.'}}], 'usage':{'prompt_tokens':100,'completion_tokens':15}})
        elif last['role']=='user' and lastuser == 'child probe':
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"Probe."}}]})
            ev({"choices":[{"delta":{"content":"probe complete"}}], "usage":{"prompt_tokens":prompt_tokens(100),"completion_tokens":10}})
        elif last['role']=='user' and lastuser.startswith('这是一次反思'):
            ev({"choices":[{"delta":{"content":"### 摘要\n反思完成。\n\n### Issue 草稿\n```json\n[{\"title\": \"write: escaping friction\", \"body\": \"seen in " + os.getcwd() + "/x.py\"}, {\"title\": \"leaky\", \"body\": \"ghp_secret\"}]\n```"}}]})
        elif last['role']=='user' and lastuser in ('interrupt me', 'interrupt stalled'):
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"想一想。"}}]})
            ev({"choices":[{"delta":{"content":"partial answer"}}]})
            time.sleep(30 if lastuser == 'interrupt stalled' else 1)
            try: ev({"choices":[{"delta":{"content":" never seen"}}]}); self.wfile.write(b'0\r\n\r\n')
            except OSError: pass
            return
        elif last['role']=='user' and lastuser == 'tool_bytes_multi':
            calls = [("run", json.dumps({"code": "await tools.read({path:'bytes-a.txt'}); 'a'"})),
                     ("not_run", "{}"), ("run", "{"), ("run", "{}"),
                     ("run", json.dumps({"code": "await tools.read({path:'bytes-b.txt'}); 'b'"}))]
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"Multiple runs."}}]})
            ev({"choices":[{"delta":{"tool_calls":[
                {"index":i, "id":f"bytes_{i}", "type":"function",
                 "function":{"name":name, "arguments":args}}
                for i, (name, args) in enumerate(calls)]}}],
                "usage":{"prompt_tokens":prompt_tokens(100),"completion_tokens":10}})
        elif last['role']=='user' or (progress_child and completed_runs < 3):
            code = 'const r = await tools.bash({command: "echo hello from bash; printf \'a\\\\nb\\\\nc\\\\n\' | wc -l"});\nconsole.log("exit", r.exit_code);\nr.output.trim().split("\\n")'
            if lastuser.startswith('delegate_cancel '):
                code = 'await tools.agent({prompt: ' + json.dumps('child cancel ' + lastuser.split(' ', 1)[1]) + '})'
            elif lastuser.startswith('delegate_timeout '):
                code = ('await tools.agent({prompt: ' + json.dumps('child timeout ' + lastuser.split(' ', 1)[1]) +
                        ', timeout_ms: 1600}).catch(e => e.message)')
            elif lastuser == 'delegate_timeout_stall':
                code = 'await tools.agent({prompt: "child stall2", timeout_ms: 1600}).catch(e => e.message)'
            elif lastuser == 'delegate_stall':
                code = 'await tools.agent({prompt: "child stall2"})'
            elif lastuser == 'delegate_failure':
                code = 'try { await tools.agent({prompt: "child reject2"}); } catch (e) { e.message }'
            elif lastuser == 'delegate_progress':
                code = 'await Promise.all([tools.agent({prompt: "child progress alpha"}), tools.agent({prompt: "child progress beta"})])'
            elif lastuser == 'delegate_many':
                code = 'await Promise.all(Array.from({length: 6}, (_, i) => tools.agent({prompt: "child " + i})))'
            elif lastuser == 'delegate_probe':
                code = 'await tools.agent({prompt: "child probe"})'
            elif lastuser == 'run_drain_read_failure':
                code = "await Promise.all([tools.bash({command:'sleep 2; echo finished > marker'}), tools.read({path:'nope.txt'})])"
            elif lastuser in ('run_drain_reject_continuation', 'run_drain_fulfill_continuation'):
                code = ('tools.bash({command: "sleep 0.1"}).then(async () => {'
                        'await tools.bash({command: "sleep 0.1"});'
                        'await tools.write({path: "marker", content: "finished\\n"});'
                        '});')
                code += ('throw new Error("original rejection");' if lastuser == 'run_drain_reject_continuation'
                         else '"fulfilled";')
            elif lastuser == 'stats_missing':
                code = 'await tools.bash({command: "nib_stats_nonexistent_command_42"})'
            elif lastuser == 'edit_test':
                code = ('await tools.write({path: "notes.txt", content: "a\\nb\\n"});\n'
                        'await tools.edit({path: "notes.txt", old_text: "b", new_text: "B"});\n'
                        'await tools.write({path: "same.txt", content: "x\\n"}); "done"')
            elif lastuser == 'run_summary_test':
                code = ('await tools.edit({path: "summary.txt", old_text: "old", '
                        'new_text: "tools.llm( tools.llm( tools.write("});'
                        '/* tools.agent( */ await tools.bash({command: "true"})')
            elif lastuser == 'run_summary_overflow':
                code = 'for (let i = 0; i < 203; i++) await tools.read({path: "summary.txt"})'
            elif lastuser == 'tool_bytes_test':
                code = ('await Promise.all([tools.read({path: "bytes-a.txt"}), tools.read({path: "bytes-b.txt"})]);'
                        '"ok"')
            elif lastuser == 'output_limit_test':
                code = ('const r = await tools.bash({command: "head -c 32768 /dev/zero | tr \'\\\\0\' x"});'
                        'if (r.output.length !== 32768) throw new Error("tool data was truncated"); r.output')
            elif lastuser == 'output_entries_test':
                code = ('const pages = await Promise.all(["left.txt", "middle.txt", "right.txt"].map(path => tools.read({path})));'
                        'pages.forEach((page, i) => console.log(["left", "middle", "right"][i], page.text));'
                        'if (pages[1].text.length !== 12012 || !pages[1].text.endsWith("-middle-tail")) throw new Error("tool data was truncated");'
                        'await tools.write({path: "middle-copy.txt", content: pages[1].text}); void 0;')
            elif lastuser == 'fetch_test':
                base = 'http://127.0.0.1:' + sys.argv[1]
                code = ('const page = await tools.fetch({url: "' + base + '/redirect"});\n'
                        'const slow = await tools.fetch({url: "' + base + '/slow", timeout_ms: 300}).catch(e => e.message);\n'
                        'const large = await tools.fetch({url: "' + base + '/large", raw: true});\n'
                        '({url: page.url, status: page.status, text: page.text, truncated: page.truncated, '
                        'large: {length: large.text.length, truncated: large.truncated, clean: /^x+$/.test(large.text)}, slow})')
            elif lastuser == 'delegate':
                code = 'await Promise.all([tools.agent({prompt: "child alpha"}), tools.agent({prompt: "child beta"})])'
            elif progress_child:
                path = 'progress-' + lastuser.split()[-1] + '.txt'
                if completed_runs == 0:
                    code = 'await tools.write({path: ' + json.dumps(path) + ', content: "one"})'
                elif completed_runs == 1:
                    code = 'await tools.edit({path: ' + json.dumps(path) + ', old_text: "one", new_text: "two"})'
                else:
                    code = 'await tools.read({path: ' + json.dumps(path) + '})'
                code += '; await tools.bash({command: "sleep 0.15"})'
            elif lastuser.startswith('child '):
                command = 'sleep 0.3'
                if lastuser.startswith('child timeout '):
                    path = lastuser.split(' ', 2)[2]
                    command = 'printf partial > ' + shlex.quote(path) + '; echo $$ > ' + shlex.quote(path + '.pid') + '; exec sleep 30'
                if lastuser.startswith('child cancel '):
                    command = 'echo $$ > ' + shlex.quote(lastuser.split(' ', 2)[2]) + '; exec sleep 30'
                code = 'await tools.bash({command: ' + json.dumps(command) + '}); ({prompt: ' + json.dumps(lastuser) + ', agent: typeof tools.agent, keys: Object.keys(tools)})'
            if 'bad' in last['content']: code='const x: number = 1; x'
            if lastuser == "timing":
                code = ('await tools.bash({command: "sleep 0.08; printf 计时🙂"}); '
                        'await tools.write({path: "timing.txt", content: "计时🙂"}); '
                        'await tools.read({path: "timing.txt"})')
            code = llm_run_code(lastuser) or code
            args=json.dumps({"code":code}, ensure_ascii=lastuser != "timing")
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"先用 bash 看看。"}}]})
            ev({"choices":[{"delta":{"content":"我先跑一下。"}}]})
            # stream the arguments in fragments, as real providers do
            ev({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"run","arguments":""}}]}}]})
            for i in range(0,len(args),7):
                ev({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":args[i:i+7]}}]}}]})
            ev({"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":prompt_tokens(100),"completion_tokens":20,"prompt_cache_hit_tokens":64}})
        else:
            if thinking: ev({"choices":[{"delta":{"reasoning_content":"结果出来了。"}}]})
            ev({"choices":[{"delta":{"content":"工具返回：" + last['content'].replace('\n',' | ')}}]})
            ev({"choices":[],"usage":{"prompt_tokens":prompt_tokens(150),"completion_tokens":10,"prompt_cache_hit_tokens":128}})
        if 'truncated' in lastuser:
            self.wfile.write(b'0\r\n\r\n'); return
        d=b'data: [DONE]\n\n'; self.wfile.write(b'%x\r\n'%len(d)+d+b'\r\n0\r\n\r\n')
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
