use v6.d;
use lib "%*ENV<HOME>/src/Raku/Terminal-Print/lib";
use lib "%*ENV<HOME>/src/Raku/raku-Terminal-Window/lib";
use Vikna::App;
use Vikna::Window;

class MyWin is Vikna::Window {
}

class MyApp is Vikna::App {
    method main {
        my $mw = $.desktop.create-child: MyWin, :w<79>, :h<30>, :x<10>, :y<10>, :title<test>;
        # $mw.invalidate;
        # $mw.redraw;
        # for 10...7 -> $c {
        #     $mw.set-geom($c, $c, 70, 30);
        #     $mw.sync-events;
        # }
        # return;

        for ^10 {
            my $nw = 79.rand.Int + 4;
            my $nh = 30.rand.Int + 4;
            my $nx = ($.desktop.w - $nw).rand.Int;
            my $ny = ($.desktop.h - $nh).rand.Int;
            my $ow = $mw.w;
            my $oh = $mw.h;
            my $ox = $mw.x;
            my $oy = $mw.y;
            my ($dw, $dh) = ($nw - $ow, $nh - $oh);
            my ($dx, $dy) = ($nx - $ox, $ny - $oy);
            my $steps = $dw.abs max $dh.abs;
            for 1..$steps -> $step {
                my $cw = ($ow + $dw × ($step / $steps)).Int;
                my $ch = ($oh + $dh × ($step / $steps)).Int;
                my $cx = ($ox + $dx × ($step / $steps)).Int;
                my $cy = ($oy + $dy × ($step / $steps)).Int;
                $mw.set-geom($cx, $cy, $cw, $ch);
                $mw.set-title: "test: $cw × $ch";
                # sleep .1;
                $mw.sync-events;
            }
        }
    }
}

my $app = MyApp.new: :!debugging;
$app.run;
