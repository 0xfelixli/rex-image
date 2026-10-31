-- Rex Paste 2: install ONLY on Air as ~/.config/rex/rex-paste.lua.
-- init.lua: require("rex-paste")
local CLI = "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
local HOME = assert(os.getenv("HOME"))
local SELF = HOME .. "/.config/rex/rex-paste.lua"
local CACHE = HOME .. "/.cache/rex-paste"
local MAX = 20 * 1024 * 1024
local FRAME = 60000 -- Fits Rex's 64 KiB control-message limit.
local function trim(s) return (s:gsub("%s+$", "")) end
local function exec(argv, opts)
    local r,e = rex.exec(argv,opts or {timeout=30})
    if not r then error(e,0) end
    if not r.ok then error(r.stderr~="" and r.stderr or r.stdout,0) end
    return r.stdout
end
local function call(name,args)
    local r,e=rex.call(name,args)
    if not r then error(e,0) end
    return r
end
local function notify(text)
    pcall(exec,{"/usr/bin/osascript","-e",
        'on run argv\ndisplay notification (item 1 of argv) with title "Rex Paste"\nend run',text})
end
local function method(s,b,m,a)
    return call("block.method",{session_id=s,block_id=b,method=m,args=a or {}})
end
local function paste(s,b,text)
    -- Bound JSON escaping overhead and never split a UTF-8 code point.
    local i=1
    while i<=#text do
        local last=math.min(i+8191,#text)
        while last<#text do
            local byte=text:byte(last+1)
            if byte<128 or byte>191 then break end
            last=last-1
        end
        call("block.event",{session_id=s,block_id=b,
            event={type="paste",payload={text=text:sub(i,last)}}})
        i=last+1
    end
end

-- One raw/no-echo receiver, no commands or new processes per data frame.
local RECEIVER=[=[
use strict; use warnings; use POSIX qw(:termios_h);
use MIME::Base64 qw(decode_base64); use Digest::SHA;
use File::Path qw(make_path); use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
$|=1; umask 0077;
my ($sha,$size,$ext,$token,$limit)=@ARGV;
my ($part,$out);
sub emit { print "RP:$token:$_[0]\n"; }
$SIG{ALRM}=sub { die "Receiver timed out"; };
$SIG{TERM}=sub { unlink $part if defined $part; exit 1; };
$SIG{HUP}=$SIG{INT}=$SIG{TERM};
eval {
    die "Invalid metadata" unless $sha=~/\A[0-9a-f]{64}\z/ && $token=~/\A[0-9a-f-]{36}\z/
        && $ext=~/\A(?:png|jpg|gif|webp)\z/ && $size=~/\A\d+\z/ && $size>0 && $size<=$limit;
    my $dir="$ENV{HOME}/.cache/rex-paste";
    make_path($dir,{mode=>0700});
    # Only our hash-named cache files, older than 30 days.
    if(opendir(my $dh,$dir)) {
        while(my $n=readdir($dh)) {
            next unless $n=~/\A[0-9a-f]{64}\.(?:png|jpg|gif|webp)(?:\.[0-9a-f-]{36}\.part)?\z/;
            my $p="$dir/$n"; my @st=lstat($p);
            unlink($p) if @st && !-l $p && -f _ && time-$st[9]>30*86400;
        }
        closedir($dh);
    }
    $out="$dir/$sha.$ext";
    if(-f $out && !-l $out && -s $out==$size) {
        open(my $old,"<",$out) or die $!; binmode $old;
        my $d=Digest::SHA->new(256); $d->addfile($old); close $old;
        if($d->hexdigest eq $sha) { utime undef,undef,$out; emit("DONE:$out"); sleep 60; exit 0; }
    }
    $part="$out.$token.part";
    sysopen(my $f,$part,O_WRONLY|O_CREAT|O_EXCL,0600) or die $!; binmode $f;
    my $t=POSIX::Termios->new; $t->getattr(0);
    $t->setlflag($t->getlflag & ~(ECHO|ICANON|ISIG|IEXTEN));
    $t->setiflag($t->getiflag & ~(ICRNL|INLCR|IGNCR|IXON));
    $t->setoflag($t->getoflag & ~OPOST);
    $t->setcc(VMIN,1); $t->setcc(VTIME,0); $t->setattr(0,TCSANOW);
    emit("READY"); my $count=0; my $d=Digest::SHA->new(256);
    while(1) {
        alarm 90;
        my $line=<STDIN>; die "Unexpected end of transfer" unless defined $line;
        $line=~s/\n\z//;
        if($line eq 'END') { last; }
        die "Invalid frame" unless length($line)<=60000 && $line=~/\A[A-Za-z0-9+\/]*={0,2}\z/ && length($line)%4==0;
        my $bytes=decode_base64($line); $count+=length($bytes);
        die "Too much data" if $count>$size;
        print $f $bytes or die $!; $d->add($bytes); emit("ACK:$count");
    }
    alarm 0; close($f) or die $!;
    die "Length mismatch" unless $count==$size;
    die "SHA256 mismatch" unless $d->hexdigest eq $sha;
    rename($part,$out) or die $!; undef $part;
    emit("DONE:$out"); sleep 60;
};
if($@) { my $e=$@; $e=~s/[\r\n]+/ /g; unlink $part if defined $part; emit("ERROR:$e"); sleep 10; exit 1; }
]=]

-- `rex do` runs here on Air, connected to the target Rex server once.
if rex.args and rex.args.worker then
    local a=rex.args
    local receiver
    local started=os.time()
    local ok,result=pcall(function()
        call("session.attach",{session_id=a.session})
        local before=method(a.session,a.block,"process")
        local original=assert(before.foreground or before.child,"Target has exited")
        assert(original.pid==a.pid and (not a.name or original.name==a.name),"Target process changed while queued")
        local f=assert(io.open(a.file,"rb")); local size=f:seek("end"); f:close()
        assert(size>0 and size<=MAX,"Image exceeds 20 MiB or is empty")
        local sha=assert(exec({"/usr/bin/shasum","-a","256",a.file}):match("^(%x+)"))
        local token=trim(exec({"/usr/bin/uuidgen"})):lower()
        local local_path
        if a.local_target then
            exec({"/bin/mkdir","-p",CACHE})
            local_path=CACHE.."/"..sha.."."..a.ext
            local staged=local_path.."."..token..".part"
            exec({"/bin/cp",a.file,staged})
            exec({"/bin/chmod","600",staged})
            assert(os.rename(staged,local_path))
        end
        local status,frames
        if not local_path then
        receiver=call("session.new_block",{
            session_id=a.session,label="image-transfer",
            flavor="com.superlogical.terminal.shell",
            options={shell="none",command={"/usr/bin/perl","-e",RECEIVER,
                sha,tostring(size),a.ext,token,tostring(MAX)},exit={on_completion=true}}
        }).block_id
        local prefix="RP:"..token..":"
        local function state()
            local text=method(a.session,receiver,"format",{format="text",trim=true,unwrap=true}).content
            local last
            for line in (text.."\n"):gmatch("([^\n]*)\n") do
                local pos=line:find(prefix,1,true)
                if pos then last=trim(line:sub(pos+#prefix)) end
            end
            if last and last:sub(1,6)=="ERROR:" then error(last:sub(7),0) end
            return last
        end
        local function wait_for(wanted)
            local deadline=os.time()+90
            while true do
                local s=state()
                if s and (s==wanted or s:sub(1,5)=="DONE:") then return s end
                assert(os.time()<deadline and os.time()-started<600,"Transfer timed out")
                rex.sleep(0.03)
            end
        end
        status=wait_for("READY")
        frames=0
        if status:sub(1,5)~="DONE:" then
            local encoded=exec({"/usr/bin/base64","-i",a.file},{timeout=30}):gsub("%s","")
            for i=1,#encoded,FRAME do
                local chunk=encoded:sub(i,i+FRAME-1)
                method(a.session,receiver,"write",{data=chunk.."\n"})
                local sent=math.min(size,math.floor((i-1+#chunk)*3/4))
                frames=frames+1
                if frames%8==0 or i+#chunk>#encoded then
                    status=wait_for("ACK:"..sent)
                end
            end
            method(a.session,receiver,"write",{data="END\n"})
            status=wait_for("DONE")
        end
        end
        local path=local_path or assert(status:match("^DONE:(.+)$"),"Missing remote path")
        frames=frames or 0
        local after=method(a.session,a.block,"process")
        local current=after.foreground or after.child
        assert(current and current.pid==original.pid and current.name==original.name,
            "Target changed; image uploaded but not pasted: "..path)
        -- A paste event, not raw keystrokes, so Codex can identify image paths.
        local text=path:find("%s") and ('"'..path:gsub('"','\\"')..'"') or path
        paste(a.session,a.block,text)
        print(rex.json.encode({path=path,bytes=size,frames=frames,seconds=os.time()-started}))
        if not a.quiet then notify("图片已上传并粘贴到原终端。") end
        return path
    end)
    if receiver then pcall(call,"block.close",{session_id=a.session,block_id=receiver}) end
    if a.temp then pcall(exec,{"/bin/rm","-rf",a.temp}) end
    if not ok then
        if not a.quiet then notify("图片粘贴失败，请查看 ~/.cache/rex-paste/upload.log") end
        error(result,0)
    end
    return
end

-- Native clipboard data is reused; only TIFF/BMP-style images need PNG encoding.
local CLIPBOARD=[=[
ObjC.import('AppKit');
function run() {
    const pb=$.NSPasteboard.generalPasteboard;
    // Text first: no image decoding, disk writes, or upload queue.
    const text=pb.stringForType($.NSPasteboardTypeString);
    if(text && !text.isNil()) return JSON.stringify({kind:'text',text:ObjC.unwrap(text)});
    function save(data,ext) {
        if(Number(data.length)>20971520) throw Error('Image exceeds 20 MiB');
        const temp=ObjC.unwrap($.NSTemporaryDirectory())+'rex-paste.'+ObjC.unwrap($.NSUUID.UUID.UUIDString);
        const fm=$.NSFileManager.defaultManager;
        if(!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(temp),false,$({NSFilePosixPermissions:448}),null))
            throw Error('Cannot create image directory');
        const file=temp+'/image.'+ext;
        if(!data.writeToFileAtomically($(file),true)) {
            fm.removeItemAtPathError($(temp),null);
            throw Error('Cannot save clipboard image');
        }
        return JSON.stringify({kind:'image',file,ext,temp});
    }
    const formats=[['public.png','png'],['public.jpeg','jpg'],['com.compuserve.gif','gif'],['org.webmproject.webp','webp']];
    for(const [type,ext] of formats) {
        const data=pb.dataForType($(type));
        if(data && !data.isNil() && Number(data.length)>0) return save(data,ext);
    }
    const image=$.NSImage.alloc.initWithPasteboard(pb);
    if(!image || image.isNil()) return JSON.stringify({kind:'empty'});
    const bitmap=$.NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation);
    return save(bitmap.representationUsingTypeProperties($.NSPNGFileType,$({})),'png');
}
]=]
-- Serialises image jobs; OS releases the advisory lock even after a crash.
local QUEUE=[=[
use strict; use Fcntl qw(:flock); umask 0077;
my($lock,$log,@cmd)=@ARGV;
open(my $f,'>>',$lock) or die $!; flock($f,LOCK_EX) or die $!;
if(-f $log && -s $log>1048576) { unlink "$log.1"; rename $log,"$log.1"; }
open(STDOUT,'>>',$log) or die $!; open(STDERR,'>&STDOUT') or die $!;
my $r=system {$cmd[0]} @cmd; exit($r==-1?127:($r & 127)?128+($r & 127):$r>>8);
]=]
rex.action{
    name="smart_image_paste",title="Paste Text or Remote Image",
    run=function(ctx)
        assert(ctx.session_id and ctx.block_id,"Focus a terminal first")
        local temp
        local handed=false
        local ok,err=pcall(function()
            local clip=rex.json.decode(exec({"/usr/bin/osascript","-l","JavaScript","-e",CLIPBOARD}))
            temp=clip.temp
            if clip.kind=="text" then paste(ctx.session_id,ctx.block_id,clip.text); return end
            if clip.kind~="image" then return end
            local p=call("block.method",{session_id=ctx.session_id,block_id=ctx.block_id,method="process"})
            local process=assert(p.foreground or p.child,"Target has exited")
            exec({"/bin/mkdir","-p",CACHE})
            local data=rex.json.encode({worker=true,session=ctx.session_id,block=ctx.block_id,
                file=clip.file,temp=temp,ext=clip.ext,pid=process.pid,name=process.name,
                local_target=not ctx.server or ctx.server==""})
            local cmd={"/usr/bin/perl","-e",QUEUE,CACHE.."/queue.lock",CACHE.."/upload.log",CLI}
            if ctx.server and ctx.server~="" then cmd[#cmd+1]="-S"; cmd[#cmd+1]=ctx.server end
            for _,v in ipairs({"do",SELF,"--args",data}) do cmd[#cmd+1]=v end
            local h,e=rex.exec.start(cmd,{detach=true})
            if not h then error(e,0) end
            handed=true
        end)
        if temp and not handed then pcall(exec,{"/bin/rm","-rf",temp}) end
        if not ok then error(err,0) end
    end,
}
rex.bind("cmd+v","smart_image_paste")
rex.bind("cmd+[KeyV]","smart_image_paste")
