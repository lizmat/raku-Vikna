use v6.e.PREVIEW;
unit package Vikna;

use Vikna::Rect;
use Vikna::Point;
use Vikna::Child;
use Vikna::Parent;
use AttrX::Mooish;

role Event is export {
    has $.origin is mooish(:lazy);  # Originating object.
    has $.dispatcher is required;   # Dispatching object. Changes on re-dispatch.
    has Bool:D $.cleared = False;

    method clear {
        $!cleared = True;
    }

    method last {
        require ::(Vikna::Events);
        ::('Vikna::Events::CX::Event::Last').new(:ev(self)).throw
    }

    method build-origin { $!dispatcher }
}

### EVENT CATEGORIES ###

# Informational events. Usually consequences of actions.
role Event::Informative does Event { }

# Commanding events like 'move', or 'resize', or 'redraw'
role Event::Command does Event {
    has Promise:D $.completed .= new;
    has Capture:D $.args = \();
}

# Various helper events
role Event::Util does Event { }

# Marks events not eligible for holding
role Event::Unholdable { }

### EVENT SUBTYPES ###

# Any geometry event without old state.
role Event::Geomish {
    # Alias `to` for Transformish sugar
    has Vikna::Rect:D $.geom is mooish(:alias<to>) is required;
}

# Widget geometry changes of any kind, including position change
role Event::Transformish does Event::Geomish {
    has Vikna::Rect:D $.from is required;
}

# Non-geometry position changes; for example, scrolling-related
role Event::Positionish {
    has Int $.x;
    has Int $.y;
}
role Event::Positional {
    has Vikna::Point:D $.from is required;
    has Vikna::Point:D $.to is required;
}

# Any color event
role Event::Colorish {
    has $.fg;
    has $.bg;
}

# Color changes of any kind.
role Event::ColorChange does Event::Colorish {
    has $.old-fg;
    has $.old-bg;
}

# Anything related to hold of events.
role Event::Holdish does Event {
    has Event:U $ev-type;
    submethod TWEAK(:$!ev-type) { }
}

# Parent/child relations
role Event::Childish does Event {
    has Vikna::Child:D $.child is required;
}
role Event::Parentish does Event {
    has Vikna::Parent:D $.parent is required;
}
role Event::Relational does Event::Childish does Event::Parentish { }

role Event::Kbd does Event { }

#### Commands ####

class Event::Cmd::Nop                 does Event::Command { }
class Event::Cmd::Close               does Event::Command { }
class Event::Cmd::SetGeom             does Event::Command { }
class Event::Cmd::SetColor            does Event::Command { }
class Event::Cmd::AddChild            does Event::Command { }
class Event::Cmd::RemoveChild         does Event::Command { }
class Event::Cmd::Clear               does Event::Command { }
class Event::Cmd::SetTitle            does Event::Command { }
class Event::Cmd::Scroll::By          does Event::Command { }
class Event::Cmd::Scroll::To          does Event::Command { }
class Event::Cmd::Scroll::SetArea     does Event::Command { }
class Event::Cmd::Scroll::Fit         does Event::Command { }
class Event::Cmd::TextScroll::AddText does Event::Command { }

class Event::Cmd::Redraw does Event::Command {
    has Promise:D $.redrawn .= new;
    method args {
        \($!redrawn, |$!args)
    }
}

class Event::Cmd::CanvasReq does Event::Command {
    has Promise:D $.response .= new;
    method args {
        \( $!response, |$!args )
    }
}

#### Informative ####

class Event::TitleChange does Event::Informative {
    has $.old-title;
    has $.title;
}

class Event::WidgetColor does Event::Informative does Event::ColorChange { }

class Event::GeomChanged does Event::Informative does Event::Transformish { }

class Event::ScreenGeom does Event::Informative does Event::Transformish { }

# Dispatched whenever widget content might have changed.
class Event::Updated does Event::Informative {
    has $.geom is required; # Widget geometry at the point of time when the event was dispatched.
}

class Event::Scroll::Position does Event::Informative does Event::Positional { }
class Event::Scroll::Area does Event::Informative does Event::Transformish { }

class Event::TextScroll::BufChange does Event::Informative {
    has Int:D $.old-size is required;
    has Int:D $.size is required;
}

class Event::KeyPressed does Event::Informative does Event::Kbd { }

class Event::Attached does Event::Informative does Event::Relational { }
class Event::Detached does Event::Informative does Event::Relational { }

#### Misc Events ####

class Event::HoldAcquire does Event::Holdish does Event::Unholdable { }
class Event::HoldRelease does Event::Holdish does Event::Unholdable { }
