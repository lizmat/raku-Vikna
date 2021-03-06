use v6.e.PREVIEW;
use Vikna::Widget;
unit class Vikna::Widget::Group;
also is Vikna::Widget;

use Vikna::Widget::GroupMember;
use Vikna::Events;
use Vikna::Utils;

### Command handlers ###

method cmd-addmember(::?CLASS:D: Vikna::Widget::GroupMember:D $member, ChildStrata:D $stratum, *%c) {
    self.Vikna::Widget::cmd-addchild($member, $stratum, |%c)
}

method cmd-removemember(::?CLASS:D: Vikna::Widget::GroupMember:D $member, *%c) {
    self.Vikna::Widget::cmd-removechild($member, |%c)
}

method cmd-redraw {
    self.trace: "Redraw group members";
    self.for-children: {
        .cmd-redraw;
    }
    nextsame;
}

### Command senders ###

method add-member(::?CLASS:D: Vikna::Widget::GroupMember:D $member, ChildStrata $stratum = StMain) {
    self.send-command: Event::Cmd::AddMember, $member, $stratum
}

method remove-member(::?CLASS:D: Vikna::Widget::GroupMember:D $member) {
    self.send-command: Event::Cmd::RemoveMember, $member
}

### Utility methods ###
# Typically, group doesn't draw itself. Even the background.
method draw(|) { }

method event-for-children(Event:D $ev) {
    self.for-children: {
        .event($ev.clone);
    }
}

method create-member(::?CLASS:D: Vikna::Widget::GroupMember:U \wtype, ChildStrata:D $stratum = StMain, *%c) {
    self.trace: "CREATING A GROUP MEMBER OF ", wtype.^name;
    my $member = self.create: wtype, :group(self), |%c;
    self.add-member: $member, $stratum;
    $member
}
