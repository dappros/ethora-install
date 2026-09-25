#!/bin/bash
echo "sleep 30..."
sleep 30
echo "after sleep 30"
mongosh --host mongo:27017 <<EOF
  var cfg = {
    _id: 'rs0',
    members: [
      { _id: 0, host: "mongo", "priority": 1 },
    ]
  }
  rs.initiate(cfg, { force: true });
  db.getMongo().setReadPref('nearest');
  rs.status();
EOF

echo "rs.initiate completed"
