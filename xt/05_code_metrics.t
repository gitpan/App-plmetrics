use Test::Perl::Metrics::Lite (
    -mccabe_complexity => 12,
    -loc => 55,
    -except_dir  => [
    ],
    -except_file => [
    ],
);

all_metrics_ok();
