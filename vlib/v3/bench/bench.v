module bench

import time
import os

pub struct Step {
pub:
	name    string
	time_us i64
	ram_kb  i64
}

pub struct Bench {
mut:
	steps []Step
	start time.StopWatch
	t0    time.StopWatch
}

pub fn new() Bench {
	return Bench{
		start: time.new_stopwatch()
		t0:    time.new_stopwatch()
	}
}

pub fn (mut b Bench) step(name string) {
	elapsed := b.t0.elapsed()
	ram := current_rss_kb()
	b.steps << Step{
		name:    name
		time_us: elapsed.microseconds()
		ram_kb:  ram
	}
	b.t0 = time.new_stopwatch()
}

pub fn (b &Bench) print_report() {
	total := b.start.elapsed()
	println('=== v3 benchmark ===')
	for s in b.steps {
		ms := f64(s.time_us) / 1000.0
		println('  ${s.name:-20s} ${ms:8.2f} ms   ${s.ram_kb:6d} KB RSS')
	}
	total_ms := f64(total.microseconds()) / 1000.0
	println('  ${'total':-20s} ${total_ms:8.2f} ms')
	println('')
}

fn current_rss_kb() i64 {
	$if macos {
		return macos_rss_kb()
	}
	$if linux {
		return linux_rss_kb()
	}
	return 0
}

fn macos_rss_kb() i64 {
	result := os.execute('ps -o rss= -p ${C.getpid()}')
	if result.exit_code == 0 {
		return result.output.trim_space().i64()
	}
	return 0
}

fn linux_rss_kb() i64 {
	content := os.read_file('/proc/self/status') or { return 0 }
	for line in content.split('\n') {
		if line.starts_with('VmRSS:') {
			parts := line.split_any(' \t').filter(it.len > 0)
			if parts.len >= 2 {
				return parts[1].i64()
			}
		}
	}
	return 0
}

fn C.getpid() int
