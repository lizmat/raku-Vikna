use v6.e.PREVIEW;
unit class Vikna::Widget;
use Vikna::Object;
use Vikna::Parent;
use Vikna::Child;
use Vikna::EventHandling;
use Vikna::CommandHandling;

also is Vikna::Object;
also does Vikna::Parent[::?CLASS];
also does Vikna::Child;
also does Vikna::EventHandling;
also does Vikna::CommandHandling;

use Vikna::Rect;
use Vikna::Events;
use Vikna::X;
use Vikna::Color;
use Vikna::Canvas;
use Vikna::Utils;
use Vikna::CAttr;
use AttrX::Mooish;

my class CanvasRecord {
    has Vikna::Rect:D $.geom is required;
    has Vikna::Canvas:D $.canvas is required;
    has @.invalidations;
}

my class AbsolutePosition {
    has Vikna::Rect $.geom;
    has Vikna::Rect $.visible;
}

has Vikna::Rect:D $.geom is required handles <x y w h>;
#| Visible part of the widget relative to the parent.
has Vikna::Rect $.viewport;
#| Rectange in absolute coordinates of the top widget (desktop)
has Vikna::Rect $.abs-geom;
#| Visible rectange of the vidget in it's parent in absolute coords.
has Vikna::Rect $.abs-viewport;

has Vikna::CAttr $.attr handles«fg bg :bg-pattern<pattern>»;
has Bool:D $.auto-clear = False;
# Is widget invisible on purpose?
has Bool:D $.hidden = False;
# Is widget visible within its parent?
has Bool:D $.invisible = False;
has Vikna::Canvas $.canvas is mooish(:lazy, :clearer, :predicate);
# Widget's geom at the moment when canvas has been drawn.
has Vikna::Rect $!canvas-geom;

has Promise:D $!closed .= new;
has Promise:D $.dismissed .= new;

has Event $!redraw-on-hold;
has Semaphore:D $!redraws .= new(1);
has atomicint $!redraw-blocks = 0;
has atomicint $!flatten-blocks = 0; # Block canvas flattenning
has atomicint $!flatten-misses = 0; # Count of requests missed while awaiting for unblock

has @.invalidations;
has Lock $.inv-lock .= new;
# Invalidations mapped into parent's coords. To be pulled out together with widget canvas for imprinting into parent's
# canvas.
has $!stash-parent-invs = []; # Invalidations for parent widget are to be stashed here first ...
has $!inv-for-parent = [];    # ... and then added here when redraw finalizes
has Lock:D $!inv4parent-lock .= new;

# Keys are Vikna::Object.id
has %!child-by-id;
has %!child-by-name; # Maps name into id

has $.inv-mark-color is rw; # For test purposes only.

multi method new(Int:D $x, Int:D $y, Dimension $w, Dimension $h, *%c) {
    self.new: geom => Vikna::Rect.new(:$x, :$y, :$w, :$h), |%c
}

multi method new(Int:D :$x, Int:D :$y, Dimension :$w, Dimension :$h, *%c) {
    self.new: geom => Vikna::Rect.new(:$x, :$y, :$w, :$h), |%c
}

multi method new(*%c where { $_<geom>:!exists }) {
    self.new: geom => Vikna::Rect.new(:0x, :0y, :20w, :10h), |%c
}

submethod TWEAK {
    self.update-positions;
}

submethod profile-checkin(%profile, %constructor, %, %) {
    unless %profile<attr> ~~ Vikna::CAttr {
        # Constructor-defined keys override those from other sources.
        %profile<attr>{$_} = %constructor<attr>{$_} // %constructor{$_} // %profile<attr>{$_} // %profile{$_}
            for <fg bg pattern>;
        %profile<attr> = cattr(|%profile<attr><fg bg pattern>)
    }
    %profile<fg bg pattern>:delete;
}

method build-canvas {
    $.create: Vikna::Canvas, geom => $!geom.clone;
}

method create-child(Vikna::Widget:U \wtype, ChildStrata $stratum = StMain, *%p) {
    $.trace: "CREATING A CHILD OF ", wtype.^name;
    my $child = $.create: wtype, |%p;
    $child.dispatch: Event::Init;
    $.trace: "NEW CHILD: ", $child.name, " // ", $child.WHICH;
    self.add-child: $child, $stratum;
    $child
}

method subscribe-to-child(Vikna::Widget:D $child) {
    self.subscribe: $child, -> $ev {
        # Redispatch only informative events as all we may need is to be posted about child changes.
        self.child-event($ev) if $ev ~~ Event::Informative
    };
}

multi method route-event(::?CLASS:D: Event::Spreadable:D $ev is copy, *%) {
    $.trace: "REDISPATCHING A SPREADABLE DEFINITE ", $ev;
    $.flow: :name(‘Spreadable:D -> children’), {
        $.for-children: {
            # Set dispatcher to child because this is how a spreadable event produced from a type object would have
            # it set.
            $.trace: "SUBMIT SPREADABLE TO CHILD ", .name;
            .dispatch: $ev.clone(:dispatcher($_))
        }
    }
    nextsame
}

multi method event(::?CLASS:D: Event::Detached:D $ev) {
    if $ev.child === self {
        if $.closed {
            # If a closed widget gets detached it's time to stop every activity.
            $.shutdown;
        }
    }
    elsif !$.closed && $ev.parent === self {
        $.redraw;
    }
}
multi method event(::?CLASS:D: Event::Attached:D $ev) {
    if $ev.child === self {
        $.update-positions: :transitive;
    }
}

proto method child-event(::?CLASS:D: Event:D) {*}
multi method child-event(::?CLASS:D: Event:D) { }

proto method subscription-event(::?CLASS:D: Event:D) {*}
multi method subscription-event(::?CLASS:D: Event:D) { }

### Command handlers ###

method !top-child-changed(ChildStrata:D $stratum) {
    # Take the current topmost child.
    with self.children($stratum).tail {
        .dispatch: $.is-bottommost($_) ?? Event::ZOrder::Bottom !! Event::ZOrder::Middle;
    }
}

method cmd-addchild(::?CLASS:D: Vikna::Widget:D $child, ChildStrata:D $stratum, :$subscribe = True) {
    $.trace: "ADDING CHILD ", $child.name;

    my $child-name = $child.name;
    $.throw: X::Widget::DuplicateName, :parent(self), :name($child-name)
        if %!child-by-name{$child-name}:exists;

    if $.elems($stratum) {
        self!top-child-changed($stratum)
    }

    if self.Vikna::Parent::add-child($child, :$stratum) {
        $.trace: " ADDED CHILD ", $child.name, " with parent: ", $child.parent.name;
        %!child-by-id{
            %!child-by-name{$child-name} = $child.id;
        } = %( :$child );
        # note self.name, " ADDED CHILD ", $child.name, " with parent: ", $child.parent.name;
        self.subscribe-to-child($child) if $subscribe;
        $child.invalidate;
        $child.redraw;
        $child.dispatch: Event::Attached, :$child, :parent(self);
        self.dispatch:   Event::Attached, :$child, :parent(self);
        if $.is-topmost($child, :on-strata) {
            $child.dispatch: Event::ZOrder::Top;
            self.dispatch:   Event::ZOrder::Child, :$child;
        }
    }
}

method cmd-removechild(::?CLASS:D: Vikna::Widget:D $child, :$unsubscribe = True) {
    self.unsubscribe: $child if $unsubscribe;
    # If a child is closing then we're its last parent and have to wait until it fully dismisses. Otherwise the child is
    # going to stick around for a while and somebody else must take care of it. Most likely it's re-parenting taking
    # place.
    %!child-by-id{$child.id}:delete;
    %!child-by-name{$child.name}:delete;
    my $is-topmost = $.is-topmost($child);
    my $is-bottommost = $.is-bottommost($child);
    my $stratum = $.child-stratum($child);
    if $child.closed {
        $.trace: "CHILD ", $child.name, " CLOSED, awaiting dismissal; current dismiss status is ", $child.dismissed.status;
        $child.dismissed.then: {
            $.trace: "CHILD ", $child.name, " DISMISSED, removing from list";
            self.Vikna::Parent::remove-child: $child;
            self.dispatch: Event::Detached, :$child, :parent(self);
        }
    }
    else {
        self.Vikna::Parent::remove-child: $child;
        self.dispatch: Event::Detached, :$child, :parent(self);
    }
    $child.dispatch: Event::Detached, :$child, :parent(self);
    if $.elems($stratum) {
        if $is-topmost {
            my $top = $.children.tail;
            $top.dispatch: Event::ZOrder::Top unless $top.closed
        }
        if $is-bottommost {
            my $bottom = $.children.head;
            $bottom.dispatch: Event::ZOrder::Bottom unless $bottom.closed;
        }
    }
}

method cmd-clear() {
    $.for-children: { .clear }, post => { self.clear-canvas };
    $.invalidate;
    $.cmd-redraw;
}

method cmd-setbgpattern(Str $new-pattern) {
    $.trace: "SET BG PATTERN to ‘$new-pattern’";
    my $old-pattern = $!attr.pattern;
    $!attr.pattern = $new-pattern;
    self.dispatch: Event::Changed::BgPattern, :$old-pattern, :$new-pattern;
    self.invalidate;
    self.redraw;
}

method cmd-sethidden($hidden) {
    if $hidden ^^ $!hidden {
        my $was-visible = $.visible;
        $!hidden = $hidden;
        $.dispatch: $!hidden ?? Event::Hide !! Event::Show;
        unless $!hidden {
            $.invalidate;
            $.redraw;
        }
        if $was-visible ^^ $.visible {
            $.dispatch: $.visible ?? Event::Visible !! Event::Invisible;
        }
    }
}

method cmd-close {
    return if $.closed;
    $.trace: "CLOSING";
    $!closed.keep(True);

    my @dismissed;
    $.for-children: {
        @dismissed.push: .dismissed;
        # Don't bother if child is already closing. Slightly relieve event flood.
        next if .closed;
        .close
    }
    $.dispatch: Event::Closing;
    Promise.allof(|@dismissed).then: {
        $.trace: "CHILDREN DISMISSED, DETACHING";
        $.detach;
    };
}

method flatten-canvas {
    $.trace: "Entering flatten-canvas, blocks count: ", $!flatten-blocks;
    if $!flatten-blocks > 0 {
        ++$!flatten-misses;
        return;
    }
    return unless $!canvas-geom; # No paints were done yet.
    my $pcanvas = $!canvas.clone;
    $pcanvas.clear-inv-rects;
    $pcanvas.invalidate: $_ for @!invalidations;
    $.for-children: -> $child {
        # Newly added children might not have drawn yet. It's ok to skip 'em.
        next unless $child.visible;
        with %!child-by-id{$child.id}<canvas> {
            $pcanvas.invalidate: $_ for .invalidations;
            $pcanvas.imprint: .geom.x, .geom.y, .canvas;
            $pcanvas.clear-inv-rects;
            $child.dispatch: Event::Updated,
                                origin => self,
                                geom => .geom;
        }
    }
    # note self.name, " pick: ", $pcanvas.pick(0,0) if self.name ~~ /Moveable/;
    with $.parent {
        $.trace: "Sending self canvas to ", .name;
        .child-canvas(self, $!canvas-geom.clone, $pcanvas, $!inv-for-parent) if $!inv-for-parent.elems > 0;
    }
    else {
        # If no parent then try sending to console.
        self.?print($pcanvas);
        $.dispatch: Event::Updated, geom => $!canvas-geom;
    }
    $!flatten-misses = 0;
}

method cmd-redraw {
    return unless $.visible;
    if $.redraw-blocked {
        $.trace: "SKIP REDRAW UNTIL UNBLOCKED";
        $.redraw;
    }
    else {
        my Vikna::Canvas:D $canvas = $!canvas;
        $.trace: "CMD REDRAW: invalidations: ", @!invalidations.elems, "\n", @!invalidations.map( "  . " ~ *.Str ).join("\n");
        if @!invalidations {
            $canvas = self.begin-draw;
            self.draw( :$canvas );
            self.end-draw( :$canvas );
            $!canvas = $canvas;
            $.flatten-canvas;
            $.trace: "REDRAWN";
        }
    }
}

method cmd-refresh {
    $.flatten-canvas;
}

method cmd-childcanvas(::?CLASS:D $child, Vikna::Rect:D $canvas-geom, Vikna::Canvas:D $canvas, @invalidations) {
    $.trace: "CHILD CANVAS FROM ", $child.name, " AT {$canvas-geom} WITH ", +@invalidations, " INVALIDATIONS:\n",
                @invalidations.map({ "  " ~ $_ }).join("\n"),
                "\nMY GEOM: " ~ $.geom;
    %!child-by-id{$child.id}<canvas> = CanvasRecord.new: :$canvas, geom => $canvas-geom, :@invalidations;
    $.flatten-canvas;
}

method cmd-setgeom(Vikna::Rect:D $geom, :$no-draw?) {
    $.trace: "Changing geom to ", $geom;
    my $from;
    cas $!geom, {
        $from = $_;
        $geom.clone
    };
    $.update-positions;
    $.trace: "Setgeom invalidations";
    $.add-inv-parent-rect: $from;
    $.invalidate;
    $.trace: "Setgeom children visibility";
    $.for-children: {
        .update-positions;
    }
    unless $no-draw {
        $.trace: "Setgeom redraw";
        $.redraw;
    }
    self.dispatch: Event::Changed::Geom, :$from, to => $!geom
        if    $from.x != $!geom.x || $from.y != $!geom.y
           || $from.w != $!geom.w || $from.h != $!geom.h;
}

method cmd-setcolor(BasicColor :$fg, BasicColor :$bg) {
    return if (!$fg || ($.attr.fg eqv $fg)) && (!$bg || ($.attr.bg eqv $bg));
    my ($old-fg, $old-bg);
    $old-fg = $.attr.fg;
    $old-bg = $.attr.bg;
    $.attr.fg = $fg;
    $.attr.bg = $bg;
    self.dispatch: Event::WidgetColor, :$old-fg, :$old-bg, :$fg, :$bg
        if ($old-fg && ($old-fg ne $fg)) || ($old-bg && ($old-bg ne $bg));
}

method cmd-to-top(::?CLASS:D $child) {
    self!top-child-changed( $.child-stratum($child) );
    self.Vikna::Parent::to-top($child);
    $.invalidate: $child.geom;
    $.flatten-canvas;
    $child.dispatch: Event::ZOrder::Top;
    self.dispatch: Event::ZOrder::Child, :$child;
}

method cmd-nop() { }

proto method cmd-contains(::?CLASS:D: Vikna::Coord:D $, |) {*}
multi method cmd-contains($obj, :$absolute! where *.so) {
    $!abs-geom.contains($obj)
}
multi method cmd-contains($obj) {
    $!geom.contains($obj)
}

### Command senders ###

method add-child(::?CLASS:D $child, ChildStrata $stratum = StMain) {
    $.send-command: Event::Cmd::AddChild, $child, $stratum;
}

method remove-child(::?CLASS:D $child) {
    $.send-command: Event::Cmd::RemoveChild, $child;
}

method child-canvas(::?CLASS:D $child, Vikna::Rect:D $canvas-geom, Vikna::Canvas:D $canvas, @invalidations) {
    $.trace: "COMMAND child-canvas for child ", $child.name, " with ", +@invalidations, " invalidations";
    my $ev = $.send-command: Event::Cmd::ChildCanvas, $child, $canvas-geom, $canvas, @invalidations;
    # $.trace: "{$ev} {$canvas.w} x {$canvas.h}, invalidations:", @invalidations.map({ "\n  $_" });
    # $.redraw;
}

method redraw {
    $.trace: "SENDING REDRAW COMMAND";
    $.send-command: Event::Cmd::Redraw;
}

method to-top(::?CLASS:D: ::?CLASS:D $child) {
    $.send-command: Event::Cmd::To::Top, $child;
}

# Widgets willing to be raised to top upon request must override this method and take action.
method maybe-to-top {
    .maybe-to-top with $.parent;
}

method clear {
    $.send-command: Event::Cmd::Clear;
}

method close {
    $.send-command: Event::Cmd::Close;
}

method quit {
    if $.app && $.app.desktop {
        $.app.desktop.quit;
    }
    else {
        $.close;
    }
}

method resize(Dimension:D $w, Dimension:D $h) {
    $.set-geom: $!geom.clone( :$w, :$h );
}

method move(Int:D $x, Int:D $y) {
    $.set-geom: $!geom.clone( :$x, :$y );
}

proto method set-geom(::?CLASS:D: |) {*}
multi method set-geom(Int:D $x, Int:D $y, Dimension:D $w, Dimension:D $h) {
    $.set-geom: Vikna::Rect.new(:$x, :$y, :$w, :$h)
}
multi method set-geom(Vikna::Rect:D $rect) {
    $.send-command: Event::Cmd::SetGeom, $rect
}

method set-color(BasicColor :$fg, BasicColor :$bg) {
    $.send-command: Event::Cmd::SetColor, :$fg, :$bg
}

method set-bg-pattern($pattern) {
    self.send-command: Event::Cmd::SetBgPattern, $pattern;
}

method set-hidden($hidden) {
    $.send-command: Event::Cmd::SetHidden, ?$hidden;
}

method hide { $.set-hidden: True }
method show { $.set-hidden: False }

method set-invisible($invisible) {
    my $changed;
    cas $!invisible, {
        $changed = $_ ^^ $invisible;
        $invisible
    };
    if $changed {
        $.dispatch: $.visible ?? Event::Visible !! Event::Invisible;
    }
}

method sync-events(:$transitive) {
    my @p;
    my $irresponsive = [];
    if $transitive {
        $.for-children: -> $chld {
            @p.push: %( widget => $chld, promise => $chld.nop[0].completed(:transitive) );
        }
    }
    @p.push: %( widget => self, promise => $.nop.head.completed );
    $.trace: "LIST OF NOPS:\n", @p.map({ "  " ~ .<widget>.name ~ " p:" ~ .<promise>.^name }).join("\n");
    my $succeed = False;
    await Promise.anyof(
        Promise.in(30),
        $.flow: :name('SYNC EVENTS'), { await eager @p.map( { $_<promise> } ); $succeed = True; }
    );
    unless $succeed {
        for @p {
            note $_<widget>.WHICH, " nop ", $_<promise>.?status.^name;
        }
        note $.name ~ " INTERNAL: {$transitive ?? "transitive " !! ""}sync-events timeout exceeded";
        self.panic: X::AdHoc.new: payload => $.name ~ " INTERNAL: {$transitive ?? "transitive " !! ""}sync-events timeout exceeded";
    }
}

method nop {
    # note self.name, " NOP";
    $.send-command: Event::Cmd::Nop
}

method contains(Vikna::Coord:D $obj, :$absolute?) {
    $.send-command: Event::Cmd::Contains, $obj, :$absolute
}

### State methods ###

method visible { ! ($!hidden || $!invisible || $.closed) }

method closed { ! ($!closed.status ~~ Planned) }

### Utility methods ###

method update-positions(:$transitive?) {
    if $.parent {
        my $parent-geom = $.parent.geom;
        my $parent-viewport = $.parent.viewport;
        my $parent-abs = $.parent.abs-geom;
        $!viewport = $!geom.clip($parent-viewport).relative-to($!geom);
        $!abs-geom = $!geom.absolute($parent-abs);
        $!abs-viewport = $!viewport.absolute($!abs-geom);
        # $.trace: "PARENT GEOMS:",
        #          "\n  geom    : ", $parent-geom,
        #          "\n  abs     : ", $parent-abs,
        #          "\n  viewport: ", $parent-viewport,
        #          "\nOWN GEOMS:",
        #          "\n  geom    : ", $!geom,
        #          "\n  abs     : ", $!abs-geom,
        #          "\n  viewport: ", $!viewport,
        #          ;
    }
    else {
        $!abs-geom = $!abs-viewport = $!geom;
        $!viewport = Vikna::Rect.new: 0, 0, $!geom.w, $!geom.h;
    }
    if $transitive {
        $.for-children: {
            .update-positions(:transitive)
        }
    }
    $.set-invisible: not ($!viewport.w && $!viewport.h);
}

method add-inv-parent-rect(Vikna::Rect:D $rect) {
    if $.parent {
        $.trace: "ADD TO STASH OF PARENT INVS: ", ~$rect;
        $!inv4parent-lock.protect: {
            $!stash-parent-invs.push: $rect
        }
    }
}

method add-inv-rect(Vikna::Rect:D $rect) {
    my $vrect = $rect.clip($!viewport);
    $!inv-lock.protect: {
        @!invalidations.push: $vrect;
    }
    $.add-inv-parent-rect: $vrect.absolute($!geom);
}

method clear-invalidations {
    $!inv-lock.protect: {
        @!invalidations = [];
    }
}

proto method invalidate(|) {*}

multi method invalidate(Vikna::Rect:D $rect) {
    $.trace: "INVALIDATE ", ~$rect, "\n -> ", $.parent.WHICH, " as ", $rect.absolute($.geom);
    $.add-inv-rect: $rect
}

multi method invalidate(UInt:D $x, UInt:D $y, Dimension $w, Dimension $h) {
    $.invalidate: Vikna::Rect.new( :$x, :$y, :$w, :$h )
}

multi method invalidate(UInt:D :$x, UInt:D :$y, Dimension :$w, Dimension :$h) {
    $.invalidate: Vikna::Rect.new( :$x, :$y, :$w, :$h )
}

multi method invalidate(@invalidations) {
    $.invalidate: $_ for @invalidations
}

multi method invalidate() {
    $.invalidate: Vikna::Rect.new( :0x, :0y, :$.w, :$.h );
}

method begin-draw(Vikna::Canvas $canvas? is copy --> Vikna::Canvas) {
    $!canvas-geom = $!geom.clone;
    $canvas //= $.create:
                    Vikna::Canvas,
                    :$.w, :$.h,
                    :$!inv-mark-color,
                    |($!auto-clear ?? () !! :from($!canvas));
    $.invalidate if $!auto-clear;
    $.trace: "begin-draw canvas (auto-clear:{$!auto-clear}): ", $canvas.WHICH, " ", $canvas.w, " x ", $canvas.h;

    for @!invalidations {
        $canvas.invalidate: $_
    }

    $canvas
}

method end-draw( :$canvas! ) {
    $.trace: "END DRAW";
    $!inv4parent-lock.protect: {
        $!inv-for-parent = @$!stash-parent-invs;
        $!stash-parent-invs = [];
    }
    self.clear-invalidations;
}

method redraw-block {
    ++⚛$!redraw-blocks;
    $.trace: "REDRAW BLOCK, block count: ", $!redraw-blocks;
    $.for-children: { .redraw-block };
}

method redraw-unblock {
    $.for-children: { .redraw-unblock };
    given --⚛$!redraw-blocks {
        when 0 {
            self!release-redraw-event;
        }
        when * < 0 {
            self.throw: X::OverUnblock, :count( .abs ), :what<redraw>;
        }
    }
    $.trace: "REDRAW UNBLOCK, block count: ", $!redraw-blocks;
}

method redraw-blocked { ? $!redraw-blocks }

method redraw-hold(&code, |c) {
    $.redraw-block;
    LEAVE $.redraw-unblock;
    &code(|c)
}

# Contrary to redraw, flattenning must not be auto-blocked on children.
method flatten-block {
    ++⚛$!flatten-blocks;
    $.trace: "Flattening block: ", $!flatten-blocks;
}

# Don't auto-flatten when counter is zeroed.
method flatten-unblock {
    with --⚛$!flatten-blocks {
        if $_ < 0 {
            $.throw: X::OverUnblock, :count($!flatten-blocks), :what('canvas flattenning')
        }
        elsif $_ == 0 && $!flatten-misses {
            if $*VIKNA-EVQ-OWNER && $*VIKNA-EVQ-OWNER === self {
                $.flatten-canvas;
            }
            else {
                self.send-command: Event::Cmd::Refresh;
            }
        }
    }
    $.trace: "Flattening un-block: ", $!flatten-blocks;
}

method flatten-hold(&code, |c) {
    $.flatten-block;
    LEAVE $.flatten-unblock;
    &code(|c)
}

method draw(:$canvas) {
    self.draw-background(:$canvas);
}

method draw-background(:$canvas) {
    if $.attr.pattern {
        $.trace: "DRAWING BACKGROUND";
        my $bgpat = $.attr.pattern;
        my $back-row = ( $bgpat x ($.w.Num / $bgpat.chars).ceiling );
        for ^$.h -> $row {
            $canvas.imprint(0, $row, $back-row, fg => $.attr.fg, bg => $.attr.bg)
        }
    }
}

method !release-redraw-event {
    # Don't release if redraws are blocked
    return if $!redraw-blocks;
    my $rh;
    cas $!redraw-on-hold, {
        # If there is a redraw event pending then release it into the wild.
        # self.trace: "RELEASE HELD EVENT with invs: ", $rh.invalidations.elems;
        $rh = $_;
        Nil
    };
    if $rh && !$.closed {
        $.trace: "Held redraw event: " ~ $rh;
        self.re-dispatch: $rh, :priority(PrioReleased) unless $.closed;
    }
}

method !hold-redraw-event($ev) {
    my $drop;
    # cas block can be ran more than once. Thus, no irreversible actions should be done and $drop flag must be set on
    # both branches of if for consistency.
    cas $!redraw-on-hold, {
        if $_ {
            $.trace: "ALREADY HOLDING ", $_;
            $drop = True;
            $_
        }
        else {
            $.trace: "RECORDING FOR HOLD ", $ev;
            $drop = False;
            $ev
        }
    };
    $.drop-event: $ev if $drop;
}

# Filters are protected from concurrency by EventHandling
multi method event-filter(Event::Cmd::Redraw:D $ev) {
    $.trace: "WIDGET EV FILTER: ", $ev, ", redraw blocks: $!redraw-blocks";
    if $!redraw-blocks == 0 && $!redraws.try_acquire {
        # There is no current redraws, we just proceed further but first make sure we release the resource when done.
        $ev.completed.then: {
            $.flow: :name('REDRAW RELEASE'), {
                $.trace: "RELEASING REDRAW SEMAPHORE";
                $!redraws.release;
                self!release-redraw-event;
            }
        };
        [$ev]
    }
    else {
        # There is another redraw active.
        $.trace: "PUT ", $ev, " on hold";
        self!hold-redraw-event: $ev;
        # This event won't go any further...
        []
    }
}

method detach {
    with $.parent {
        $.trace: "DETACHING FROM PARENT ", (.?name // .WHICH);
        .remove-child: self;
    }
    else {
        $.trace: "DETACHING, NO PARENT";
        $.dispatch: Event::Detached, :child(self), :parent(self);
    }
}

method shutdown {
    $.stop-event-handling.then: {
        $!dismissed.keep(True);
    }
}

method panic($cause) {
    my $bail-out = True;
    if $.app && $.app.desktop {
        $.app.desktop.dismissed.then: { $bail-out = False; };
        await Promise.anyof(
            Promise.in(10),
            start $.app.panic($cause, :object(self))
        );
    }
    else {
        nextsame;
    }
    exit 1 if $bail-out;
}

proto method get-child(::?CLASS:D: |) {*}
multi method get-child(Str:D $name --> Vikna::Widget) {
    %!child-by-name{$name}:exists ?? %!child-by-id{ %!child-by-name{$name} }<child> !! Nil
}
multi method get-child(Int:D $id --> Vikna::Widget) {
    %!child-by-id{$id}:exists ?? %!child-by-id{$id}<child> !! Nil
}

proto method AT-KEY(|) {*}
multi method AT-KEY(::?CLASS:D: Str:D $wname) {
    %!child-by-name{$wname} ?? %!child-by-id{ %!child-by-name{$wname} }<child> !! Nil
}
multi method AT-KEY(::?CLASS:D: Int $id) {
    %!child-by-id{ $id }<child>
}
multi method AT-KEY(::?CLASS:U: |) { Nil }

proto method EXISTS-KEY(|) {*}
multi method EXISTS-KEY(::?CLASS:D: Str:D $wname) {
    %!child-by-name{$wname}:exists
}
multi method EXISTS-KEY(::?CLASS:D: Int:D $id) {
    %!child-by-id{$id}:exists
}
multi method EXISTS-KEY(::?CLASS:U: |) { False }

proto method DELETE-KEY(|) {*}
multi method DELETE-KEY(::?CLASS:D: Str:D $wname) {
    $.remove-child: $_ with $.get-child($wname);
}
multi method DELETE-KEY(::?CLASS:D: Int:D $id) {
    $.remove-child: $_ with $.get-child($id);
}

method Bool {
    self.defined && $!closed.status ~~ Planned
}

method Str {
    $.name
}

method gist {
    $.id ~ ":" ~ $.name
}
