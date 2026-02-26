# blog

A hypermedia-driven application written in Lua for RedBean webserver: deploys a simple blog with a RESTful API and a dynamic pages Linux, Unix, BSD, or Windows with a single binary. Shoutouts to [RedBean](https://redbean.dev/), [Fullmoon](https://github.com/pkulchenko/fullmoon), and [HTMX](https://htmx.org/) for making this possible.

## Contributing 

Contributions are welcome! Please open an issue or submit a pull request with your changes. 

## License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## Requirements

All requirements are pulled during maketime with `curl` using GNU `make`. 
Because it's awesome, the fatbin should work robustly on most OSes, daemons may need to use the `ape` loader, rather than running the binary directly. 

## Building

First, clone the repository and navigate to the project directory:

```bash
git clone https://github.com/stephenszwiec/blog.git 
cd blog
```

Then, edit the local variables in `.lua/app.lua` to your liking. This changes the blog's title, description, and author information. 

Finally run  `make` and `make setup` to build the application and set up the database, producing `blog.com` and `blog.db` in the project directory. 

## Running

### Development  

```bash 
./blog.com 
``` 
Will run the application on `localhost:8080` and attempt to open your default browser to the blog. 

### HTTPS 

```
./redbean.com -p 443 \
  -K privkey.pem \
  -C fullchain.pem \
  -J
```
Will run the application on `localhost:443` with TLS and mandatory HTTPS using the provided certificates.

### Daemon 

#### Systemd Service 

First, produce a daemon user and copy the application files to its home directory:

```bash
sudo useradd -r -s /usr/sbin/nologin -d /var/lib/blog blog
cp blog.com /var/lib/blog/blog.com
cp blog.db /var/lib/blog/blog.db
sudo chown -R blog:blog /var/lib/blog 
``` 

Then, deploy your TLS certificates to `/var/lib/blog/privkey.pem` and `/var/lib/blog/fullchain.pem` with similar permissions. Consider using a hook in your certificate management tool to automate this process.

Finally, make sure your system has a working [ape](https://justine.lol/ape.html) loader.
```
which ape
```

Create `/etc/systemd/system/blog.service`:

```ini
[Unit]
Description=Hypermedia Blog (Redbean)
After=network.target

[Service]
Type=simple
User=blog
WorkingDirectory=/var/lib/blog
ExecStart=ape \
  /var/lib/blog.com -p 443 -p 80 \
  -K privkey.pem \
  -C fullchain.pem \
  -J
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

Then enable and start the service:

```bash
sudo systemctl enable blog.service 
sudo systemctl start blog.service 
```

#### OpenRC Service 

As above, you produce a daemon user, a copy of the application files, and deploy your TLS certificates. 

Then, create `/etc/init.d/blog`:

```bash
#!/sbin/openrc-run
command="/usr/bin/ape"
command_args="/var/lib/blog.com -p 443 -p 80 \
  -K privkey.pem \
  -C fullchain.pem \
  -J"
command_user="blog:blog"
depend() {
  need net
}
```
Make the script executable and add it to the default runlevel:

```bash
sudo chmod +x /etc/init.d/blog 
sudo rc-update add blog default 
```

Finally, start the service:

```bash
sudo rc-service blog start 
``` 

## Notes 

- **Database**: `blog.db` is created automatically at first request in the working directory. 
- **Admin access**: Visit `/login`, enter your password. A session cookie (HttpOnly, SameSite=Strict, 7-day TTL) is set on success. Sessions are stored in `blog.db` and survive server restarts. `/edit` is the admin page.
- **Rate limiting**: Login is limited to 5 attempts per IP per 15 minutes. The contact form allows 3 submissions per IP per hour. Both limits are in-memory and reset on restart. 
- **CSRF tokens**: Every mutating form includes a `csrf_token` hidden field validated against an HttpOnly SameSite=Strict cookie.
- **Password changes**: Re-run `./redbean.com -i setup_admin.lua` at any time. The new hash overwrites the old one immediately.
