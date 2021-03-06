use v6.e.PREVIEW;

unit class Vikna::Window;

use Vikna::Widget::Group;
use Vikna::Focusable;
use Vikna::Elevatable;
use Vikna::PointerTarget;
use Vikna::Events;
use Vikna::Utils;
use Vikna::Border;
use Vikna::Widget::GroupMember;
use Vikna::Widget;

also does Vikna::Elevatable;
also does Vikna::PointerTarget;
also does Vikna::Focusable;
also is   Vikna::Widget::Group;
also does Vikna::Widget::NeverTop;

class Event::Cmd::Window::CompleteRedraw is Event::Command is export { }

class Client {
    also does Vikna::PointerTarget;
    also does Vikna::Focusable;
    also is Vikna::Widget::GroupMember;

    # Don't allow voluntary client geom change.
    method set-geom(|) { }

    method set-title(|c) { $.group.set-title(|c) }
}

has Str:D $.title = "";
has Vikna::Border $.border;
has Client $.client handles qw<
                                cmd-addchild cmd-removechild cmd-setbgpattern
                                AT-KEY EXISTS-KEY DELETE-KEY get-child
                            >;

submethod TWEAK(Bool:D :$border = True) {
    if $border {
        self.trace: "ADDING BORDER";
        $!border = self.create-member:
                        Vikna::Border, StBack,
                        :name(self.name ~ ":Border"),
                        :w( self.w ), :h( self.h ), :x(0), :y(0),
                        # :!auto-clear,
                        ;
    }
    self.trace: "ADDING CLIENT";
    my $cgeom = Vikna::Rect.new(self.client-rect(.w, .h)) with self.geom;
    $!client = self.create-member:
                    Client,
                    :name(self.name ~ ":Client"),
                    :geom($cgeom),
                    :attr(self.attr),
                    :focused-attr(self.focused-attr),
                    # :inv-mark-color<00,30,00>,
                    :auto-clear( self.auto-clear );
    # self.inv-mark-color = '0,50,0';
}

submethod profile-default {
    attr => {
        :fg<default>, :bg<default>, :style(' '), :pattern(' ')
    },
    focused-attr => {
        :fg<white>, :bg<blue>, :style(' '), :pattern(' ')
    }
}

### Event handlers ###

### Command handlers ###

method cmd-settitle(Str:D $title) {
    my $from = $!title;
    $!title = $title;
    with $!border {
        .invalidate: 0, 0, .w, 1;
        .cmd-redraw;
    }
    self.dispatch: Event::Changed::Title, :$from, :to($title);
}

method cmd-setgeom(Int:D $x, Int:D $y, Int:D $w, Int:D $h) {
    self.trace: { "WINDOW GEOM TO ", Vikna::Rect.new(:$x, :$y, :$w, :$h) };
    self.Vikna::Widget::cmd-setgeom($x, $y, $w, $h, :no-draw);
    $!client.cmd-setgeom: |self.client-rect($w, $h), :no-draw;
    if $!border {
        $!border.cmd-setgeom: 0, 0, $w, $h, :no-draw;
    }
    $.cmd-redraw;
    self.trace: { "WINDOW GEOM SET {$.geom}" };
}

method cmd-redraw {
    self.trace: "Window redraw";
    $.flatten-block;
    $!border.cmd-redraw;
    $!client.cmd-redraw;
    # With common event queue we can guarantee that CompleteRedraw command will arrive after both border and client had
    # their ChildCanvas events dispatched and handled accordingly. In the meanwhile their canvas would be preserved but
    # won't result extra submission of window's canvas to the parent. In other words, we'd simulate synchronous draw.
    self.send-command: Event::Cmd::Window::CompleteRedraw;
}

method cmd-window-completeredraw {
    self.Vikna::Widget::Group::cmd-redraw;
    $.flatten-unblock;
}

method cmd-setcolor(|c) {
    $!client.cmd-setcolor(|c);
    nextsame;
}

method cmd-setstyle(|c) {
    $!client.cmd-setstyle(|c);
    nextsame
}

method cmd-setattr(|c) {
    $!client.cmd-setattr(|c);
    nextsame
}

method cmd-addmember(::?CLASS:D: Vikna::Widget::GroupMember:D $member, |) {
    callsame;
    if $member === $!client {
        $.cmd-focus-request($member)
    }
}

### Event handlers ###

### Command senders ###
method set-title(Str:D $title) {
    self.send-command: Event::Cmd::SetTitle, $title;
}

method resize(Int:D $w is copy where * > 0 = $.w, Int:D $h is copy where * > 0 = $.h) {
    my $min = $!border ?? 4 !! 2;
    $w max= $min;
    $h max= $min;
    nextwith($w, $h)
}

method child-canvas(::?CLASS:D: |c) {
    self.cmd-childcanvas: |c;
}

method maybe-to-top {
    $.parent.to-top: self;
    nextsame;
}

### Utility methods ###
proto method client-rect(|) {*}
multi method client-rect(Vikna::Rect:D $geom) {
    self.client-rect: .w, .h with $geom
}
multi method client-rect($cw is copy, $ch is copy) {
    my $cx = 0;
    my $cy = 0;
    if $!border {
        ++$cx; ++$cy;
        $cw -= 2;
        $ch -= 2;
    }
    $cx, $cy, $cw, $ch
}
