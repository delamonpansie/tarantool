#!/usr/bin/ruby

$: << File.dirname($0) + '/lib'
require 'run_env'

class Env < RunEnv
  def config
    super + <<EOD
object_space[0].enabled = 1
object_space[0].index[0].type = "TREE"
object_space[0].index[0].unique = 1
object_space[0].index[0].key_field[0].fieldno = 0
object_space[0].index[0].key_field[0].type = "STR"

EOD
  end
end

Env.connect_eval do
  10.times do |i| insert [i.to_s] end

  lua 'user_proc.iterator', '0', '5', '5'
  lua 'user_proc.iterator', '0', '5', '5', 'backward'
  lua 'user_proc.iterator', '0', '5', '5', 'forward', '3'
  lua 'user_proc.iterator', '0', '5', '5', 'backward', '3'
end
