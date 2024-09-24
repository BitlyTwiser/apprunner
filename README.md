<div align="center"> 

# Apprunner
<img src="/assets/apprunner.jpg" width="450" height="500">
</div>

The premise is simple: add commands to the yml file,run the program, get windows running your stuff! 

Apprunner will build N number of named Tmux windows running the commands you provide. If given a path (and not standalone), the window will be opened at that directory location running the given command.

# Prerequisites/Setup:
1. You DO need Tmux for this: https://github.com/tmux/tmux/wiki
2. Download the release for your system: https://github.com/BitlyTwiser/apprunner/releases
3. Fill out the yaml
example:
```
apps:
  - name: test1
    command: ping google.com
    standalone: true
    start_location: ./var/thing
  - name: test2
    command: ls -la
    standalone: false 
    start_location: /var/log
```
3. run `./apprunner -config_path=<path_to_yaml_config>`
4. Terminal with your set commands will appear:
![Screenshot](/assets/screenshot1.png)
![Screenshot](/assets/screenshot2.png)

# How it works:
- This program executes tmux hooks to spawn a session, then add N number of windows to the session passing the keys to the given window. I.e. command -> window -> execute.
Example from the CLI:
```
tmux new-session -s test_sesh \; rename-window -t test_sesh:0 inner_window \; send-keys -t test_sesh:inner_window 'echo "hi" |base64' enter
```
This will spawn a new tmux session, create & rename the window, and run the command echoing hi to base64 encode.

# Usage Examples:
Aside from the above example, here are some examples 

Standard configuration path
```
./zig-out/bin/apprunner -config_path="test_config.yml"
```
restore:
``` 
./zig-out/bin/apprunner -restore=true
```

# Environment Variables
If you desire to insert a specific set of environment variables to the tmux session at runtime you can add the `env_path` to the yaml file.
The env will be loaded *per session*. For each app that is inserted, the values will be injected for that session.
THis is done using the `-e` flag from the tmux api.

Example:
```
apps:
  - name: test1
    command: ping google.com
    standalone: true
    start_location: ./var/thing
  - name: test2
    command: ls -la
    standalone: false 
    start_location: /var/log
    env_path: .env
```
Note the `env_path` value. This specifies that the .env file should be co-located next to the binary.

You can also use relative paths:
```
apps:
  - name: test1
    command: ping google.com
    standalone: true
    start_location: ./var/thing
  - name: test2
    command: ls -la
    standalone: false 
    start_location: /var/log
    env_path: ../../.env
```

Or full absolute paths:
```
apps:
  - name: test1
    command: ping google.com
    standalone: true
    start_location: ./var/thing
  - name: test2
    command: ls -la
    standalone: false 
    start_location: /var/log
    env_path: /home/place/.env
```


## Roadmap:
- [ ] Multi-pane per window support. Instead of windows only, allow for user to select a split pane layout (i.e. split pane horizontal/vertical etc..)
- [X] Save/Store runtime progress (like tmux resurrect)
- [X] Env file loading (provide an .env and have the values loaded into the application)
