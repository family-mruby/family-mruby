#!/usr/bin/env ruby
# frozen_string_literal: true
#
# fmrb_ros2_types.rb: refresh the ROS 2 message types bundled with Family
# mruby (fmruby-core/doc/ruby_asterism, R3).
#
#   ruby tools/fmrb_ros2_types.rb             # refresh the bundled types
#   ruby tools/fmrb_ros2_types.rb --check     # only compare, change nothing
#   ruby tools/fmrb_ros2_types.rb --fixtures  # refresh the test fixtures
#
# 1. Copies the .msg / .srv / .json of the needed packages out of the ROS 2
#    image (docker-compose.ros2.yml's fmruby-ros2-jazzy-zenoh:local; built if
#    missing) into a temporary directory.
# 2. Checks every type hash asterism_msggen.rb computes against the type
#    description JSON of the image; any mismatch stops here.
# 3. Copies the definitions used into
#    fmruby-core/lib/add/picoruby-asterism/tools/ros2_jazzy/ and writes the
#    JSON's hashes to ros2_jazzy/type_hashes.txt (the host tests read these,
#    so they run without docker).
# 4. Regenerates fmruby-core/flash/usr/share/asterism/msgs/ from
#    tools/bundled_types.txt.
#
# --fixtures refreshes what the host tests (fmruby-core/test/asterism_msgs)
# compare with, again from the ROS 2 tools in the image (Python there; the
# image has no Ruby):
# - test_type_hashes.txt: the hashes rosidl_generator_type_description
#   computes for the test package asterism_test_msgs (bounded strings and
#   sequences, wstring, defaults, a service), which Jazzy does not ship.
# - golden_cdr.tsv: for each case of golden_cases.json, the CDR bytes
#   rclpy.serialization.serialize_message makes (rmw_zenoh_cpp, Fast-CDR).
require "fileutils"
require "json"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CORE = File.join(ROOT, "fmruby-core")
GEM_TOOLS = File.join(CORE, "lib/add/picoruby-asterism/tools")
require File.join(GEM_TOOLS, "asterism_msggen")

IMAGE = "fmruby-ros2-jazzy-zenoh:local"
PACKAGES = %w[std_msgs builtin_interfaces geometry_msgs sensor_msgs example_interfaces service_msgs].freeze
VENDOR = File.join(GEM_TOOLS, "ros2_jazzy")
OUT = File.join(CORE, "flash/usr/share/asterism/msgs")
LIST = File.join(GEM_TOOLS, "bundled_types.txt")

check_only = ARGV.include?("--check")
TEST_DIR = File.join(CORE, "test/asterism_msgs")

REF_HASH_PY = <<~PY
  import json, pathlib, tempfile
  from rosidl_adapter.msg import convert_msg_to_idl
  from rosidl_adapter.srv import convert_srv_to_idl
  from rosidl_generator_type_description import generate_type_hash
  pkg = "asterism_test_msgs"
  pkg_dir = pathlib.Path("/work") / pkg
  out = pathlib.Path(tempfile.mkdtemp())
  tuples = []
  for kind, conv in (("msg", convert_msg_to_idl), ("srv", convert_srv_to_idl)):
      for f in sorted((pkg_dir / kind).glob("*." + kind)):
          conv(pkg_dir, pkg, pathlib.Path(kind) / f.name, out / "idl" / kind)
          tuples.append(f"{out / 'idl'}:{kind}/{f.stem}.idl")
  deps = ("std_msgs", "geometry_msgs", "builtin_interfaces", "service_msgs")
  args = {"package_name": pkg, "output_dir": str(out / "td"), "idl_tuples": tuples,
          "include_paths": [f"{p}:/opt/ros/jazzy/share/{p}" for p in deps]}
  (out / "args.json").write_text(json.dumps(args))
  hashes = {}
  for f in generate_type_hash(str(out / "args.json")):
      for th in json.loads(pathlib.Path(f).read_text())["type_hashes"]:
          hashes[th["type_name"]] = th["hash_string"]
  for k in sorted(hashes):
      print("HASH", k, hashes[k])
PY

GOLDEN_PY = <<~PY
  import json
  from rosidl_runtime_py.utilities import get_message, get_service
  from rosidl_runtime_py import set_message_fields
  from rclpy.serialization import serialize_message
  for name, values in json.load(open("/work/golden_cases.json")):
      if "/srv/" in name:
          base, part = name.rsplit("_", 1)
          cls = getattr(get_service(base), part)
      else:
          cls = get_message(name)
      text = json.dumps(values, separators=(",", ":"))
      m = cls()
      set_message_fields(m, values)
      print(name + "\t" + text + "\t" + serialize_message(m).hex())
PY

def in_image(py)
  cmd = "docker run --rm -i -v #{TEST_DIR}:/work:ro #{IMAGE} " \
        "bash -c 'source /opt/ros/jazzy/setup.bash && python3 - 2>/dev/null'"
  out = IO.popen(cmd, "r+") do |io|
    io.write(py)
    io.close_write
    io.read
  end
  abort "failed in the image: #{cmd}" unless $?.success?
  out
end

def sh!(cmd)
  system(cmd) || abort("failed: #{cmd}")
end

unless system("docker image inspect #{IMAGE} > /dev/null 2>&1")
  sh!("docker compose -f #{ROOT}/docker-compose.yml -f #{ROOT}/docker-compose.ros2.yml build ros2")
end

if ARGV.include?("--fixtures")
  unless system("docker image inspect #{IMAGE} > /dev/null 2>&1")
    sh!("docker compose -f #{ROOT}/docker-compose.yml -f #{ROOT}/docker-compose.ros2.yml build ros2")
  end
  lines = in_image(REF_HASH_PY).lines.grep(/\AHASH /).map { |l| l.split[1..].join(" ") }
  File.write(File.join(TEST_DIR, "test_type_hashes.txt"),
             "# RIHS01 hashes of asterism_test_msgs from rosidl_generator_type_description\n" \
             "# (ROS 2 Jazzy, #{IMAGE}). Written by tools/fmrb_ros2_types.rb --fixtures.\n" +
             lines.map { |l| "#{l}\n" }.join)
  gold = in_image(GOLDEN_PY)
  File.write(File.join(TEST_DIR, "golden_cdr.tsv"), gold)
  puts "#{lines.size} reference hashes, #{gold.lines.size} golden CDR cases -> #{TEST_DIR}"
  exit 0
end

names = File.readlines(LIST).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }

Dir.mktmpdir("fmrb_ros2_types") do |tmp|
  dirs = PACKAGES.flat_map { |p| %W[#{p}/msg #{p}/srv] }.join(" ")
  sh!("docker run --rm #{IMAGE} bash -c 'cd /opt/ros/jazzy/share && tar cf - #{dirs} 2>/dev/null; true' " \
      "| tar xf - -C #{tmp}")
  reg = AsterismMsgGen::Registry.new([tmp])
  hasher = AsterismMsgGen::Hasher.new(reg)
  all = AsterismMsgGen.closure(reg, names)
  checked, bad, missing = AsterismMsgGen.check_json(hasher, all, [tmp])
  bad.each { |n, mine, theirs| warn "MISMATCH #{n}: computed #{mine}, json #{theirs}" }
  missing.each { |n| warn "no JSON for #{n}" }
  puts "type hashes against the image's JSON: #{checked} checked, #{bad.size} mismatched, #{missing.size} missing"
  abort "stopping: the type hashes do not match" unless bad.empty? && missing.empty?

  hashes = {}
  all.each do |full|
    pkg, kind, name = AsterismMsgGen.split_name(full)
    JSON.parse(File.read(File.join(tmp, pkg, kind, "#{name}.json")))["type_hashes"].each do |th|
      hashes[th["type_name"]] = th["hash_string"]
    end
  end
  exit 0 if check_only

  FileUtils.rm_rf(VENDOR)
  reg.sources.each do |src|
    rel = src.delete_prefix("#{tmp}/")
    dst = File.join(VENDOR, rel)
    FileUtils.mkdir_p(File.dirname(dst))
    FileUtils.cp(src, dst)
  end
  File.open(File.join(VENDOR, "type_hashes.txt"), "w") do |f|
    f.puts "# RIHS01 type hashes from the type description JSON of ROS 2 Jazzy"
    f.puts "# (/opt/ros/jazzy/share/<pkg>/<msg|srv>/<Name>.json in #{IMAGE})."
    f.puts "# Written by tools/fmrb_ros2_types.rb; the host tests compare with these."
    hashes.keys.sort.each { |k| f.puts "#{k} #{hashes[k]}" }
  end
  puts "#{reg.sources.size} definitions and #{hashes.size} hashes -> #{VENDOR}"

  # Regenerate the bundle from the copied definitions (what the tests do).
  reg2 = AsterismMsgGen::Registry.new([VENDOR])
  em = AsterismMsgGen::Emitter.new(reg2, AsterismMsgGen::Hasher.new(reg2))
  FileUtils.rm_rf(OUT)
  files = AsterismMsgGen.closure(reg2, names)
  files.each do |n|
    path = File.join(OUT, AsterismMsgGen::Emitter.rel_path(n))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, em.file(n))
  end
  bytes = files.sum { |n| File.size(File.join(OUT, AsterismMsgGen::Emitter.rel_path(n))) }
  puts "#{files.size} types (#{bytes} bytes) -> #{OUT}"
end
